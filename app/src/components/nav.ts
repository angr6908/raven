import {
  BarChart3,
  Boxes,
  CircleDollarSign,
  Home,
  Users,
} from "lucide-react"

export const NAV = [
  { id: "overview", label: "Overview", icon: Home },
  { id: "usage", label: "Usage", icon: BarChart3 },
  { id: "accounts", label: "Accounts", icon: Users },
  { id: "models", label: "Models", icon: Boxes },
  { id: "pricing", label: "Pricing", icon: CircleDollarSign },
] as const

export type PanelPage = (typeof NAV)[number]["id"]

export const NAV_LABEL = Object.fromEntries(
  NAV.map((n) => [n.id, n.label])
) as Record<PanelPage, string>
