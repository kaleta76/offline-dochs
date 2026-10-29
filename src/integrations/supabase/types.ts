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
          name: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          id?: string
          name: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          id?: string
          name?: string
        }
        Relationships: []
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
      punches: {
        Row: {
          client_time: string
          client_uuid: string
          code: string
          device: string | null
          direction: string
          drift_minutes: number
          id: number
          prev_hash: string | null
          record_hash: string | null
          server_time: string
          source: string
          user_id: string
        }
        Insert: {
          client_time: string
          client_uuid: string
          code: string
          device?: string | null
          direction: string
          drift_minutes?: number
          id?: number
          prev_hash?: string | null
          record_hash?: string | null
          server_time?: string
          source?: string
          user_id: string
        }
        Update: {
          client_time?: string
          client_uuid?: string
          code?: string
          device?: string | null
          direction?: string
          drift_minutes?: number
          id?: number
          prev_hash?: string | null
          record_hash?: string | null
          server_time?: string
          source?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "punches_code_fkey"
            columns: ["code"]
            isOneToOne: false
            referencedRelation: "absence_codes"
            referencedColumns: ["code"]
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
      calc_settings: {
        Args: never
        Returns: {
          key: string
          value: string
        }[]
      }
      can_see: { Args: { _emp: string }; Returns: boolean }
      decide_correction: {
        Args: { _approve: boolean; _id: string }
        Returns: undefined
      }
      has_role: {
        Args: {
          _role: Database["public"]["Enums"]["app_role"]
          _user_id: string
        }
        Returns: boolean
      }
      is_closed: { Args: { _t: string; _user: string }; Returns: boolean }
      is_manager_of: { Args: { _emp: string }; Returns: boolean }
      my_organization: { Args: never; Returns: string }
      rotate_organization_invite: { Args: never; Returns: string }
      same_organization: { Args: { _user: string }; Returns: boolean }
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
