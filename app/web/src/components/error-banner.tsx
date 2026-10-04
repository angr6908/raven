import { Card, CardContent } from "@/components/ui/card"

export function ErrorBanner({ error }: { error?: string | null }) {
  if (!error) return null
  return (
    <Card className="border-destructive/50">
      <CardContent className="pt-6 text-sm text-destructive">
        {error}
      </CardContent>
    </Card>
  )
}
