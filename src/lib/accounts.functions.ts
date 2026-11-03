import { createServerFn } from '@tanstack/react-start';
import { createClient } from '@supabase/supabase-js';
import { z } from 'zod';
import { requireSupabaseAuth } from '@/integrations/supabase/auth-middleware';
import { employeeAccessSchema, enrollmentSchema, employeeAuthEmail } from './account-rules';
import { personnelNumberSchema } from './personnel';

export const employeeLogin = createServerFn({ method: 'POST' }).inputValidator((v: unknown) => employeeAccessSchema.parse(v)).handler(async ({ data }) => {
  const { supabaseAdmin } = await import('@/integrations/supabase/client.server');
  const { data: profile } = await supabaseAdmin.from('profiles').select('id').eq('organization_id', data.organization).eq('sap_id', data.number).maybeSingle();
  if (!profile) throw new Error('Nesprávne prihlasovacie údaje.');
  const { data: account } = await supabaseAdmin.auth.admin.getUserById(profile.id);
  if (!account.user?.email || account.user.app_metadata['onboarding_pending']) throw new Error('Nesprávne údaje alebo účet vyžaduje dokončenie registrácie.');
  const url = process.env['SUPABASE_URL']; const key = process.env['SUPABASE_PUBLISHABLE_KEY'];
  if (!url || !key) throw new Error('Prihlásenie nie je dostupné.');
  const client = createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});
  const { data: auth, error } = await client.auth.signInWithPassword({email:account.user.email,password:data.password});
  if (error || !auth.session) throw new Error('Nesprávne prihlasovacie údaje.');
  return { access_token: auth.session.access_token, refresh_token: auth.session.refresh_token };
});

export const provisionEmployee = createServerFn({ method:'POST' }).middleware([requireSupabaseAuth]).inputValidator((v:unknown)=>z.object({number:personnelNumberSchema,userId:z.string().uuid().optional()}).parse(v)).handler(async ({data,context})=>{
  const {data:allowed,error:roleError}=await context.supabase.rpc('has_role',{_user_id:context.userId,_role:'admin'});
  if(roleError || !allowed) throw new Error('Iba správca môže pridať alebo obnoviť účet.');
  const {data:org,error:orgError}=await context.supabase.rpc('my_organization');
  if(orgError || !org) throw new Error('Organizácia nie je dostupná.');
  if(data.userId){const {data:p}=await context.supabase.from('profiles').select('id,organization_id,sap_id').eq('id',data.userId).maybeSingle();if(!p || p.organization_id!==org || p.sap_id!==data.number)throw new Error('Účet nie je dostupný.');}
  const {supabaseAdmin}=await import('@/integrations/supabase/client.server');
  const pin=Array.from(crypto.getRandomValues(new Uint8Array(16)),b=>b.toString(16).padStart(2,'0')).join('');
  const expires=Date.now()+24*60*60*1000;
  let id=data.userId;
  if(id){const {error}=await supabaseAdmin.auth.admin.updateUserById(id,{password:pin,app_metadata:{onboarding_pending:true,pin_expires:expires}});if(error)throw new Error('Obnova účtu sa nepodarila.');await supabaseAdmin.auth.admin.signOut((await supabaseAdmin.auth.admin.getUserById(id)).data.user?.id ?? '', 'global');}
  else {
    const {data:invite}=await context.supabase.from('organization_invites').select('code').eq('organization_id',org).single();
    if(!invite)throw new Error('Pozvanie nie je dostupné.');
    const {data:created,error}=await supabaseAdmin.auth.admin.createUser({email:employeeAuthEmail(org,data.number),password:pin,email_confirm:true,user_metadata:{invite_code:invite.code,sap_id:data.number},app_metadata:{onboarding_pending:true,pin_expires:expires}});
    if(error || !created.user)throw new Error('Osobné číslo alebo účet už existuje; skontrolujte údaje.');id=created.user.id;
  }
  const {error}=await context.supabase.rpc('audit_account_event',{_target:id,_action:data.userId?'employee_password_reset':'employee_provisioned'});if(error)throw new Error('Účet bol pripravený, audit sa nepodaril. Kontaktujte správcu.');
  return {pin,organization:org};
});

export const enrollEmployee=createServerFn({method:'POST'}).inputValidator((v:unknown)=>enrollmentSchema.parse(v)).handler(async ({data})=>{
  const {supabaseAdmin}=await import('@/integrations/supabase/client.server');
  const {data:p}=await supabaseAdmin.from('profiles').select('id').eq('organization_id',data.organization).eq('sap_id',data.number).maybeSingle();
  if(!p)throw new Error('Neplatný alebo expirovaný PIN.');
  const {data:a}=await supabaseAdmin.auth.admin.getUserById(p.id);
  if(!a.user?.email || !a.user.app_metadata['onboarding_pending'] || Number(a.user.app_metadata['pin_expires'])<Date.now())throw new Error('Neplatný alebo expirovaný PIN.');
  const url=process.env['SUPABASE_URL'];const key=process.env['SUPABASE_PUBLISHABLE_KEY'];if(!url || !key)throw new Error('Registrácia nie je dostupná.');
  const client=createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data:auth,error}=await client.auth.signInWithPassword({email:a.user.email,password:data.pin});
  if(error || auth.user?.id!==p.id)throw new Error('Neplatný alebo expirovaný PIN.');
  const {error:updateError}=await supabaseAdmin.auth.admin.updateUserById(p.id,{password:data.password,...(data.email?{email:data.email,email_confirm:true}:{}),app_metadata:{onboarding_pending:false,pin_expires:null}});
  if(updateError)throw new Error('Účet sa nepodarilo dokončiť.');
  await supabaseAdmin.from('audit_log').insert({actor:p.id,action:'employee_enrollment_completed',target:p.id});
  await client.auth.signOut();
  return {completed:true};
});