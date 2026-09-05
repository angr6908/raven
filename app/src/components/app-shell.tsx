import { NAV, NAV_LABEL, type PanelPage } from "@/components/nav"
import { RavenMark } from "@/components/logo"
import type { Health } from "@/lib/api"
import {
  Sidebar,
  SidebarContent,
  SidebarGroup,
  SidebarGroupContent,
  SidebarGroupLabel,
  SidebarHeader,
  SidebarInset,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarProvider,
  SidebarRail,
  SidebarTrigger,
} from "@/components/ui/sidebar"

export function AppShell({
  page,
  onNavigate,
  health,
  children,
}: {
  page: PanelPage
  onNavigate: (p: PanelPage) => void
  health?: Health
  children: React.ReactNode
}) {
  return (
    <SidebarProvider defaultOpen>
      <Sidebar collapsible="offcanvas">
        <SidebarHeader>
          <div className="flex items-center gap-3.5 px-2 py-1.5">
            <RavenMark className="size-7 shrink-0 text-primary" />
            <div className="grid min-w-0 flex-1 leading-tight">
              <span className="truncate font-mono text-sm font-semibold">Raven</span>
              <span className="truncate font-mono text-[11px] font-medium uppercase tracking-[0.04em] text-muted-foreground">
                api console
              </span>
            </div>
            {health?.status === "ok" && (
              <span
                title={`proxy ok · v${health.version}`}
                className="relative flex size-2 shrink-0"
              >
                <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-emerald-500 opacity-60" />
                <span className="relative inline-flex size-2 rounded-full bg-emerald-500" />
              </span>
            )}
          </div>
        </SidebarHeader>

        <SidebarContent>
          <SidebarGroup>
            <SidebarGroupLabel>Panel</SidebarGroupLabel>
            <SidebarGroupContent>
              <SidebarMenu>
                {NAV.map((item) => (
                  <SidebarMenuItem key={item.id}>
                    <SidebarMenuButton
                      href={`#${item.id}`}
                      isActive={page === item.id}
                      onClick={() => onNavigate(item.id)}
                    >
                      <item.icon />
                      <span>{item.label}</span>
                    </SidebarMenuButton>
                  </SidebarMenuItem>
                ))}
              </SidebarMenu>
            </SidebarGroupContent>
          </SidebarGroup>
        </SidebarContent>

        <SidebarRail />
      </Sidebar>

      <SidebarInset>
        <header className="sticky top-0 z-10 flex h-14 items-center gap-3 border-b bg-background/95 px-4 backdrop-blur">
          <SidebarTrigger />
          <h1 className="text-sm font-medium">{NAV_LABEL[page]}</h1>
        </header>
        <main className="flex min-w-0 max-w-full flex-1 flex-col gap-6 p-4 md:p-6">
          {children}
        </main>
      </SidebarInset>
    </SidebarProvider>
  )
}
