export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.18"
  }
  public: {
    Tables: {
      absence_codes: {
        Row: {
          calc_type: string
          code: string
          counts: boolean
          limit_days: number | null
          name: string
          sap_code: string
          sort: number
        }
        Insert: {
          calc_type: string
          code: string
          counts?: boolean
          limit_days?: number | null
          name: string
          sap_code: string
          sort?: number
        }
        Update: {
          calc_type?: string
          code?: string
          counts?: boolean
          limit_days?: number | null
          name?: string
          sap_code?: string
          sort?: number
        }
        Relationships: []
      }
      access_config: {
        Row: {
          config: Json
          config_version: string
          employee_months_count: number
          employees_count: number
          imported_at: string
          imported_by: string | null
          organization_id: string
          period_from: string
          period_to: string
        }
        Insert: {
          config: Json
          config_version: string
          employee_months_count: number
          employees_count: number
          imported_at?: string
          imported_by?: string | null
          organization_id: string
          period_from: string
          period_to: string
        }
        Update: {
          config?: Json
          config_version?: string
          employee_months_count?: number
          employees_count?: number
          imported_at?: string
          imported_by?: string | null
          organization_id?: string
          period_from?: string
          period_to?: string
        }
        Relationships: [
          {
            foreignKeyName: "access_config_imported_by_fkey"
            columns: ["imported_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "access_config_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: true
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      audit_log: {
        Row: {
          action: string
          actor: string | null
          at: string
          details: Json | null
          id: number
          target: string | null
        }
        Insert: {
          action: string
          actor?: string | null
          at?: string
          details?: Json | null
          id?: number
          target?: string | null
        }
        Update: {
          action?: string
          actor?: string | null
          at?: string
          details?: Json | null
          id?: number
          target?: string | null
        }
        Relationships: []
      }
      corrections: {
        Row: {
          at_time: string
          code: string
          created_at: string
          decided_at: string | null
          decided_by: string | null
          direction: string
          id: string
          reason: string
          status: string
          user_id: string
        }
        Insert: {
          at_time: string
          code: string
          created_at?: string
          decided_at?: string | null
          decided_by?: string | null
          direction: string
          id?: string
          reason: string
          status?: string
          user_id: string
        }
        Update: {
          at_time?: string
          code?: string
          created_at?: string
          decided_at?: string | null
          decided_by?: string | null
          direction?: string
          id?: string
          reason?: string
          status?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "corrections_code_fkey"
            columns: ["code"]
            isOneToOne: false
            referencedRelation: "absence_codes"
            referencedColumns: ["code"]
          },
        ]
      }
      devices: {
        Row: {
          approved_at: string | null
          approved_by: string | null
          created_at: string
          device_token_hash: string
          id: string
          last_seen_at: string | null
          organization_id: string
          pairing_code: string | null
          pairing_expires_at: string | null
          recovery_code_hash: string | null
          recovery_code_pending: string | null
          replaces_device_id: string | null
          revoke_reason: string | null
          revoked_at: string | null
          revoked_by: string | null
          status: string
          user_agent_hint: string | null
          user_id: string
        }
        Insert: {
          approved_at?: string | null
          approved_by?: string | null
          created_at?: string
          device_token_hash: string
          id?: string
          last_seen_at?: string | null
          organization_id: string
          pairing_code?: string | null
          pairing_expires_at?: string | null
          recovery_code_hash?: string | null
          recovery_code_pending?: string | null
          replaces_device_id?: string | null
          revoke_reason?: string | null
          revoked_at?: string | null
          revoked_by?: string | null
          status?: string
          user_agent_hint?: string | null
          user_id: string
        }
        Update: {
          approved_at?: string | null
          approved_by?: string | null
          created_at?: string
          device_token_hash?: string
          id?: string
          last_seen_at?: string | null
          organization_id?: string
          pairing_code?: string | null
          pairing_expires_at?: string | null
          recovery_code_hash?: string | null
          recovery_code_pending?: string | null
          replaces_device_id?: string | null
          revoke_reason?: string | null
          revoked_at?: string | null
          revoked_by?: string | null
          status?: string
          user_agent_hint?: string | null
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "devices_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "devices_replaces_device_id_fkey"
            columns: ["replaces_device_id"]
            isOneToOne: false
            referencedRelation: "devices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "devices_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      employee_month_plan: {
        Row: {
          calendar_id: number
          config_version: string
          day_types: string[]
          employment_pct: number
          expected_min: number[]
          fund_id: number
          month: string
          organization_id: string
          personnel_number: string
          regime_ids: number[] | null
          template_id: number
          window_end_min: number | null
          window_start_min: number | null
        }
        Insert: {
          calendar_id: number
          config_version: string
          day_types: string[]
          employment_pct: number
          expected_min: number[]
          fund_id: number
          month: string
          organization_id: string
          personnel_number: string
          regime_ids?: number[] | null
          template_id: number
          window_end_min?: number | null
          window_start_min?: number | null
        }
        Update: {
          calendar_id?: number
          config_version?: string
          day_types?: string[]
          employment_pct?: number
          expected_min?: number[]
          fund_id?: number
          month?: string
          organization_id?: string
          personnel_number?: string
          regime_ids?: number[] | null
          template_id?: number
          window_end_min?: number | null
          window_start_min?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "employee_month_plan_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      holidays: {
        Row: {
          day: string
          name: string
        }
        Insert: {
          day: string
          name: string
        }
        Update: {
          day?: string
          name?: string
        }
        Relationships: []
      }
      month_closures: {
        Row: {
          closed_at: string
          closed_by: string
          month: number
          user_id: string
          year: number
        }
        Insert: {
          closed_at?: string
          closed_by: string
          month: number
          user_id: string
          year: number
        }
        Update: {
          closed_at?: string
          closed_by?: string
          month?: number
          user_id?: string
          year?: number
        }
        Relationships: []
      }
      notification_preferences: {
        Row: {
          manual_punches: boolean
          new_devices: boolean
          user_id: string
        }
        Insert: {
          manual_punches?: boolean
          new_devices?: boolean
          user_id: string
        }
        Update: {
          manual_punches?: boolean
          new_devices?: boolean
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "notification_preferences_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: true
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      organization_codes: {
        Row: {
          calc_type: string
          code: string
          counts: boolean
          limit_days: number | null
          name: string
          organization_id: string
          sap_code: string
          sort: number
        }
        Insert: {
          calc_type: string
          code: string
          counts?: boolean
          limit_days?: number | null
          name: string
          organization_id?: string
          sap_code: string
          sort?: number
        }
        Update: {
          calc_type?: string
          code?: string
          counts?: boolean
          limit_days?: number | null
          name?: string
          organization_id?: string
          sap_code?: string
          sort?: number
        }
        Relationships: [
          {
            foreignKeyName: "organization_codes_code_fkey"
            columns: ["code"]
            isOneToOne: false
            referencedRelation: "absence_codes"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "organization_codes_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      organization_holidays: {
        Row: {
          day: string
          name: string
          organization_id: string
        }
        Insert: {
          day: string
          name: string
          organization_id?: string
        }
        Update: {
          day?: string
          name?: string
          organization_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "organization_holidays_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      organization_invites: {
        Row: {
          code: string
          organization_id: string
        }
        Insert: {
          code?: string
          organization_id: string
        }
        Update: {
          code?: string
          organization_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "organization_invites_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: true
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      organization_settings: {
        Row: {
          description: string | null
          key: string
          organization_id: string
          value: string
        }
        Insert: {
          description?: string | null
          key: string
          organization_id?: string
          value?: string
        }
        Update: {
          description?: string | null
          key?: string
          organization_id?: string
          value?: string
        }
        Relationships: [
          {
            foreignKeyName: "organization_settings_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      organizations: {
        Row: {
          created_at: string
          created_by: string | null
          id: string
          is_test: boolean
          name: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          id?: string
          is_test?: boolean
          name: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          id?: string
          is_test?: boolean
          name?: string
        }
        Relationships: []
      }
      personnel_requests: {
        Row: {
          created_at: string
          decided_at: string | null
          decided_by: string | null
          id: string
          requested_number: string
          status: string
          user_id: string
        }
        Insert: {
          created_at?: string
          decided_at?: string | null
          decided_by?: string | null
          id?: string
          requested_number: string
          status?: string
          user_id: string
        }
        Update: {
          created_at?: string
          decided_at?: string | null
          decided_by?: string | null
          id?: string
          requested_number?: string
          status?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "personnel_requests_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      profiles: {
        Row: {
          created_at: string
          daily_fund: number
          department: string | null
          email: string | null
          full_name: string
          id: string
          manager_id: string | null
          organization_id: string | null
          sap_id: string | null
        }
        Insert: {
          created_at?: string
          daily_fund?: number
          department?: string | null
          email?: string | null
          full_name?: string
          id: string
          manager_id?: string | null
          organization_id?: string | null
          sap_id?: string | null
        }
        Update: {
          created_at?: string
          daily_fund?: number
          department?: string | null
          email?: string | null
          full_name?: string
          id?: string
          manager_id?: string | null
          organization_id?: string | null
          sap_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "profiles_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "profiles_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      punch_void_requests: {
        Row: {
          created_at: string
          decided_at: string | null
          decided_by: string | null
          id: string
          punch_id: number
          reason: string
          requested_by: string
          status: string
          user_id: string
        }
        Insert: {
          created_at?: string
          decided_at?: string | null
          decided_by?: string | null
          id?: string
          punch_id: number
          reason: string
          requested_by: string
          status?: string
          user_id: string
        }
        Update: {
          created_at?: string
          decided_at?: string | null
          decided_by?: string | null
          id?: string
          punch_id?: number
          reason?: string
          requested_by?: string
          status?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "punch_void_requests_punch_id_fkey"
            columns: ["punch_id"]
            isOneToOne: false
            referencedRelation: "punches"
            referencedColumns: ["id"]
          },
        ]
      }
      punches: {
        Row: {
          client_time: string
          client_uuid: string
          code: string
          device: string | null
          device_id: string | null
          device_token: string | null
          device_verification: string
          direction: string
          drift_minutes: number
          id: number
          prev_hash: string | null
          record_hash: string | null
          server_time: string
          source: string
          user_id: string
          void_request_id: string | null
          voided_at: string | null
        }
        Insert: {
          client_time: string
          client_uuid: string
          code: string
          device?: string | null
          device_id?: string | null
          device_token?: string | null
          device_verification?: string
          direction: string
          drift_minutes?: number
          id?: number
          prev_hash?: string | null
          record_hash?: string | null
          server_time?: string
          source?: string
          user_id: string
          void_request_id?: string | null
          voided_at?: string | null
        }
        Update: {
          client_time?: string
          client_uuid?: string
          code?: string
          device?: string | null
          device_id?: string | null
          device_token?: string | null
          device_verification?: string
          direction?: string
          drift_minutes?: number
          id?: number
          prev_hash?: string | null
          record_hash?: string | null
          server_time?: string
          source?: string
          user_id?: string
          void_request_id?: string | null
          voided_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "punches_code_fkey"
            columns: ["code"]
            isOneToOne: false
            referencedRelation: "absence_codes"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "punches_device_id_fkey"
            columns: ["device_id"]
            isOneToOne: false
            referencedRelation: "devices"
            referencedColumns: ["id"]
          },
        ]
      }
      settings: {
        Row: {
          description: string | null
          key: string
          value: string
        }
        Insert: {
          description?: string | null
          key: string
          value?: string
        }
        Update: {
          description?: string | null
          key?: string
          value?: string
        }
        Relationships: []
      }
      user_roles: {
        Row: {
          id: string
          role: Database["public"]["Enums"]["app_role"]
          user_id: string
        }
        Insert: {
          id?: string
          role: Database["public"]["Enums"]["app_role"]
          user_id: string
        }
        Update: {
          id?: string
          role?: Database["public"]["Enums"]["app_role"]
          user_id?: string
        }
        Relationships: []
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      approve_device: {
        Args: { _as_backup?: boolean; _id: string }
        Returns: undefined
      }
      audit_account_event: {
        Args: { _action: string; _target: string }
        Returns: undefined
      }
      calc_settings: {
        Args: never
        Returns: {
          key: string
          value: string
        }[]
      }
      can_see: { Args: { _emp: string }; Returns: boolean }
      can_see_personnel: { Args: { _pn: string }; Returns: boolean }
      claim_recovery_code: { Args: { _token_hash: string }; Returns: string }
      confirm_unverified_punch: {
        Args: { _punch_id: number }
        Returns: undefined
      }
      decide_correction: {
        Args: { _approve: boolean; _id: string }
        Returns: undefined
      }
      decide_personnel_request: {
        Args: { _approve: boolean; _id: string }
        Returns: undefined
      }
      decide_punch_void: {
        Args: { _approve: boolean; _id: string }
        Returns: undefined
      }
      delete_test_organization: {
        Args: { _confirm_name: string }
        Returns: Json
      }
      device_manager_ok: { Args: { _user: string }; Returns: boolean }
      get_my_profile: { Args: never; Returns: Json }
      has_role: {
        Args: {
          _role: Database["public"]["Enums"]["app_role"]
          _user_id: string
        }
        Returns: boolean
      }
      hash_recovery_code: { Args: { _code: string }; Returns: string }
      import_access_config: {
        Args: { _dry_run?: boolean; _payload: Json }
        Returns: Json
      }
      is_closed: { Args: { _t: string; _user: string }; Returns: boolean }
      is_manager_of: { Args: { _emp: string }; Returns: boolean }
      my_organization: { Args: never; Returns: string }
      new_pairing_code: { Args: never; Returns: string }
      new_recovery_code: { Args: never; Returns: string }
      purge_organization: { Args: { _org: string }; Returns: Json }
      recover_device: {
        Args: {
          _new_token_hash: string
          _recovery_code: string
          _ua_hint: string
        }
        Returns: string
      }
      register_device: {
        Args: { _replace?: boolean; _token_hash: string; _ua_hint: string }
        Returns: {
          device_id: string
          pairing_code: string
          pairing_expires_at: string
          status: string
        }[]
      }
      request_punch_void: {
        Args: { _punch_id: number; _reason: string }
        Returns: string
      }
      revoke_device: {
        Args: { _id: string; _reason: string }
        Returns: undefined
      }
      rotate_organization_invite: { Args: never; Returns: string }
      same_organization: { Args: { _user: string }; Returns: boolean }
      set_organization_test: { Args: { _is_test: boolean }; Returns: undefined }
      test_organization_summary: { Args: never; Returns: Json }
      verify_punch_synced: {
        Args: {
          p_client_time: string
          p_client_uuid: string
          p_code: string
          p_device: string
          p_direction: string
        }
        Returns: boolean
      }
    }
    Enums: {
      app_role: "employee" | "manager" | "admin"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends (DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never) = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends (PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never) = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {
      app_role: ["employee", "manager", "admin"],
    },
  },
} as const
