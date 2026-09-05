import { useCallback, useEffect, useState } from "react"
import {
  Bot,
  FolderSearch,
  KeyRound,
  Pencil,
  Plus,
  RefreshCw,
  Save,
  Trash2,
  User,
  X,
} from "lucide-react"

import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"
import { Switch } from "@/components/ui/switch"
import { Textarea } from "@/components/ui/textarea"
import {
  type Account,
  type AccountLimits,
  type AccountProvider,
  type WorkbuddyStatus,
  addAccount,
  addWorkbuddyAccount,
  editAccount,
  getWorkbuddyOAuthStatus,
  getWorkbuddyStatus,
  readWorkbuddyLocal,
  refreshWorkbuddy,
  removeAccount,
  startWorkbuddyOAuth,
} from "@/lib/api"
import { Dash } from "@/components/dash"
import {
  type UsagePeriod,
  CommandCodeUsageCell,
} from "@/components/account-limits"
import { ErrorBanner } from "@/components/error-banner"
import { errorMessage } from "@/lib/utils"

interface EditDraft {
  target: string
  name: string
  key: string
  session_token: string
}

function changedFields(draft: EditDraft): Record<string, string> {
  const fields = ["key", "session_token"] as const
  return Object.fromEntries(
    fields
      .map((field) => [field, draft[field].trim()])
      .filter(([, value]) => value !== "")
  )
}

function Section({
  title,
  count,
  description,
  actions,
  children,
}: {
  title: string
  count?: number
  description: string
  actions?: React.ReactNode
  children: React.ReactNode
}) {
  return (
    <Card>
      <CardHeader className="flex flex-row flex-wrap items-start justify-between gap-3">
        <div className="grid flex-1 gap-1.5">
          <CardTitle className="flex items-center gap-2">
            {title}
            {count != null ? <Badge variant="secondary">{count}</Badge> : null}
          </CardTitle>
          <CardDescription>{description}</CardDescription>
        </div>
        {actions ? (
          <div className="flex shrink-0 items-center gap-2">{actions}</div>
        ) : null}
      </CardHeader>
      <CardContent className="overflow-x-auto">{children}</CardContent>
    </Card>
  )
}

function EmptyState({
  icon: Icon,
  title,
  hint,
  action,
}: {
  icon: React.ComponentType<{ className?: string }>
  title: string
  hint: string
  action: React.ReactNode
}) {
  return (
    <div className="flex flex-col items-center gap-2 py-10 text-center">
      <Icon className="size-6 text-muted-foreground/60" />
      <p className="text-sm font-medium">{title}</p>
      <p className="max-w-sm text-xs text-muted-foreground">{hint}</p>
      <div className="mt-2">{action}</div>
    </div>
  )
}

function FormPanel({ children }: { children: React.ReactNode }) {
  return (
    <div className="mb-4 border p-4">
      <div className="grid gap-4">{children}</div>
    </div>
  )
}

const PERIOD_COLUMNS: { id: UsagePeriod; header: string }[] = [
  { id: "fiveHour", header: "5-hour" },
  { id: "weekly", header: "Weekly" },
  { id: "monthly", header: "Monthly" },
]

export function Accounts({
  accounts,
  limits,
  onChanged,
}: {
  accounts: Account[]
  limits?: AccountLimits[]
  onChanged: () => void
}) {
  const [name, setName] = useState("")
  const [key, setKey] = useState("")
  const [sessionToken, setSessionToken] = useState("")
  const [wbAuth, setWbAuth] = useState("")
  const [wbNote, setWbNote] = useState<string>()
  const [wbOAuth, setWbOAuth] = useState<{
    session: string
    url: string
  } | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string>()
  const [edit, setEdit] = useState<EditDraft | null>(null)
  const [addFor, setAddFor] = useState<AccountProvider | null>(null)
  const [wbStatus, setWbStatus] = useState<WorkbuddyStatus>()

  const hasWorkbuddy = accounts.some((a) => a.provider === "workbuddy")
  const loadWbStatus = useCallback(() => {
    void getWorkbuddyStatus()
      .then(setWbStatus)
      .catch(() => setWbStatus(undefined))
  }, [])
  useEffect(() => {
    if (hasWorkbuddy) loadWbStatus()
  }, [hasWorkbuddy, loadWbStatus])

  useEffect(() => {
    if (!wbOAuth) return
    let cancelled = false
    const timer = setInterval(() => {
      void getWorkbuddyOAuthStatus(wbOAuth.session)
        .then((st) => {
          if (cancelled || !st.done) return
          setWbOAuth(null)
          if (st.success) {
            onChanged()
            loadWbStatus()
          } else {
            setError(st.error || "WorkBuddy sign-in failed")
          }
        })
        .catch(() => {
        })
    }, 3000)
    return () => {
      cancelled = true
      clearInterval(timer)
    }
  }, [wbOAuth, onChanged, loadWbStatus])

  async function run(action: () => Promise<unknown>, fallback: string) {
    setBusy(true)
    setError(undefined)
    try {
      await action()
      onChanged()
    } catch (err) {
      setError(errorMessage(err, fallback))
    } finally {
      setBusy(false)
    }
  }

  function openAdd(p: AccountProvider) {
    setAddFor((prev) => (prev === p ? null : p))
  }

  function clearAddFields() {
    setName("")
    setKey("")
    setSessionToken("")
    setWbAuth("")
    setWbNote(undefined)
  }

  function cancelAdd() {
    setAddFor(null)
    clearAddFields()
  }

  function startEdit(a: Account) {
    setEdit({
      target: a.name,
      name: a.name,
      key: a.key,
      session_token: a.session_token ?? "",
    })
  }

  const setDraft = (field: keyof EditDraft, value: string) =>
    setEdit((prev) => (prev ? { ...prev, [field]: value } : prev))

  function handleEdit(e: React.FormEvent) {
    e.preventDefault()
    if (!edit) return
    const renamed = edit.name.trim()
    void run(async () => {
      await editAccount({
        name: edit.target,
        ...(renamed && renamed !== edit.target ? { new_name: renamed } : {}),
        ...changedFields(edit),
      })
      setEdit(null)
    }, "Failed to edit account")
  }

  function handleAdd(e: React.FormEvent) {
    e.preventDefault()
    if (addFor === "workbuddy") {
      if (!wbAuth.trim()) return
      void run(async () => {
        await addWorkbuddyAccount(wbAuth.trim())
        setAddFor(null)
        clearAddFields()
        loadWbStatus()
      }, "Failed to add WorkBuddy account")
      return
    }
    if (!name.trim()) return
    void run(async () => {
      await addAccount({
        name: name.trim(),
        provider: addFor ?? "commandcode",
        key: key.trim() || undefined,
        session_token: sessionToken.trim() || undefined,
      })
      setAddFor(null)
      clearAddFields()
    }, "Failed to add account")
  }

  async function handleReadLocal() {
    setBusy(true)
    setError(undefined)
    setWbNote(undefined)
    try {
      const res = await readWorkbuddyLocal()
      if (res.found && res.auth_json) {
        setWbAuth(res.auth_json)
        setWbNote(
          `Loaded ${res.nickname || res.uid || "account"}${
            res.source ? ` from ${res.source}` : ""
          }`
        )
      } else {
        setError(
          `No local WorkBuddy credential found.${
            res.searched?.length ? ` Looked in: ${res.searched.join(", ")}` : ""
          } Sign in with the CodeBuddy desktop app first, or paste the JSON.`
        )
      }
    } catch (err) {
      setError(errorMessage(err, "Failed to read local credentials"))
    } finally {
      setBusy(false)
    }
  }

  const handleRemove = (n: string) =>
    void run(() => removeAccount(n), "Failed to remove account")

  const setAccountEnabled = (account: Account, enabled: boolean) =>
    void run(
      () => editAccount({ name: account.name, disabled: !enabled }),
      "Failed to update account"
    )

  const handleRefreshWorkbuddy = () =>
    void run(async () => {
      const status = await refreshWorkbuddy()
      setWbStatus(status)
    }, "Failed to refresh WorkBuddy")

  async function handleWorkbuddySignIn() {
    setBusy(true)
    setError(undefined)
    try {
      const start = await startWorkbuddyOAuth()
      window.open(start.url, "_blank", "noopener,noreferrer")
      setAddFor(null)
      setWbOAuth({ session: start.session, url: start.url })
    } catch (err) {
      setError(errorMessage(err, "Failed to start WorkBuddy sign-in"))
    } finally {
      setBusy(false)
    }
  }

  const editable = edit
    ? accounts.find((a) => a.name === edit.target)
    : undefined

  const commandAccounts = accounts.filter((a) => a.provider === "commandcode")
  const workbuddyAccounts = accounts.filter((a) => a.provider === "workbuddy")
  const wbStatusByUid = new Map(
    (wbStatus?.accounts ?? []).map((s) => [s.uid, s])
  )

  const limitsByName = new Map((limits ?? []).map((l) => [l.name, l]))

  const addForm = addFor ? (
    <FormPanel>
      <form onSubmit={handleAdd} className="grid gap-4">
        {}
        {addFor === "commandcode" ? (
          <div className="grid gap-1.5">
            <Label htmlFor="acct-name">Account name</Label>
            <Input
              id="acct-name"
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="e.g. work"
            />
          </div>
        ) : null}

        {addFor === "workbuddy" ? (
          <>
            <div className="grid gap-1.5">
              <div className="flex items-center justify-between gap-2">
                <Label htmlFor="acct-wb-auth">Auth JSON (or sign in)</Label>
                <Button
                  type="button"
                  variant="outline"
                  size="xs"
                  onPress={() => void handleReadLocal()}
                  isDisabled={busy}
                >
                  <FolderSearch className="size-3" />
                  Read from local
                </Button>
              </div>
              <Textarea
                id="acct-wb-auth"
                value={wbAuth}
                onChange={(e) => setWbAuth(e.target.value)}
                placeholder='Sign in with the button, click "Read from local" to load the CodeBuddy desktop credential, or paste: {"auth":{"accessToken":"…","refreshToken":"…","expiresAt":…},"account":{"uid":"…","nickname":"…"}}'
                className="min-h-24 font-mono text-[11px]"
              />
              {wbNote ? (
                <span className="text-[11px] text-muted-foreground">
                  {wbNote}
                </span>
              ) : null}
            </div>
            <div className="flex items-center gap-2">
              <Button type="submit" isDisabled={busy || !wbAuth.trim()}>
                <Plus className="size-4" />
                Add WorkBuddy
              </Button>
              <Button
                type="button"
                variant="outline"
                onPress={() => void handleWorkbuddySignIn()}
                isDisabled={busy || wbOAuth != null}
              >
                Sign in
              </Button>
              <Button type="button" variant="ghost" onPress={cancelAdd}>
                <X className="size-3.5" />
                Cancel
              </Button>
            </div>
          </>
        ) : (
          <>
            <div className="grid gap-1.5">
              <Label htmlFor="acct-key">API key</Label>
              <Input
                id="acct-key"
                value={key}
                onChange={(e) => setKey(e.target.value)}
                placeholder="user_..."
                type="password"
              />
            </div>
            <div className="grid gap-1.5">
              <Label htmlFor="acct-token">Session token (optional)</Label>
              <Input
                id="acct-token"
                value={sessionToken}
                onChange={(e) => setSessionToken(e.target.value)}
                placeholder="GYFdU4ejGttJfYvot... (session_token value)"
                type="text"
                className="font-mono text-xs"
              />
            </div>
            <div className="flex items-center gap-2">
              <Button
                type="submit"
                isDisabled={busy || !name.trim() || !key.trim()}
              >
                <Plus className="size-4" />
                Add account
              </Button>
              <Button type="button" variant="ghost" onPress={cancelAdd}>
                <X className="size-3.5" />
                Cancel
              </Button>
            </div>
          </>
        )}
      </form>
    </FormPanel>
  ) : null

  const editForm =
    editable && edit ? (
      <FormPanel>
        <form onSubmit={handleEdit} className="grid gap-4">
          <div className="grid gap-4 md:grid-cols-2">
            <div className="grid gap-1.5">
              <Label htmlFor="edit-name">Name</Label>
              <Input
                id="edit-name"
                value={edit.name}
                onChange={(e) => setDraft("name", e.target.value)}
              />
            </div>
            <div className="grid gap-1.5">
              <Label htmlFor="edit-key">API key</Label>
              <Input
                id="edit-key"
                value={edit.key}
                onChange={(e) => setDraft("key", e.target.value)}
                className="font-mono text-xs"
                type="text"
              />
            </div>
            <div className="grid gap-1.5">
              <Label htmlFor="edit-token">Session token</Label>
              <Input
                id="edit-token"
                value={edit.session_token}
                onChange={(e) => setDraft("session_token", e.target.value)}
                className="font-mono text-xs"
                type="text"
              />
            </div>
          </div>
          <div className="flex items-center gap-2">
            <Button type="submit" size="sm" isDisabled={busy}>
              <Save className="size-3.5" />
              Save
            </Button>
            <Button
              type="button"
              variant="ghost"
              size="sm"
              onPress={() => setEdit(null)}
            >
              <X className="size-3.5" />
              Cancel
            </Button>
          </div>
        </form>
      </FormPanel>
    ) : null

  return (
    <div className="flex flex-col gap-6">
      <ErrorBanner error={error} />

      {}
      {wbOAuth ? (
        <div className="flex flex-wrap items-center gap-2 rounded-lg border bg-muted/40 px-3 py-2 text-sm">
          <RefreshCw className="size-3.5 animate-spin text-muted-foreground" />
          <span>
            Waiting for sign-in — complete the login at{" "}
            <a
              href={wbOAuth.url}
              target="_blank"
              rel="noopener noreferrer"
              className="font-medium underline underline-offset-2"
            >
              {wbOAuth.url}
            </a>
            .
          </span>
        </div>
      ) : null}

      {}
      <Section
        title="Command Code"
        count={commandAccounts.length}
        description="API-key accounts (key + optional session token). All enabled accounts share one pool — each request drains the account with the least remaining headroom, so one is used up before the next takes over."
        actions={
          <Button
            variant="outline"
            size="sm"
            onPress={() => openAdd("commandcode")}
            isDisabled={busy}
          >
            <Plus className="size-3.5" />
            {addFor === "commandcode" ? "Close" : "Add"}
          </Button>
        }
      >
        {addFor === "commandcode" ? addForm : null}
        {editable?.provider === "commandcode" ? editForm : null}
        {commandAccounts.length === 0 ? (
          <EmptyState
            icon={KeyRound}
            title="No Command Code accounts"
            hint="Add an account with its API key — every enabled account joins the shared pool, drained one at a time."
            action={
              <Button
                variant="outline"
                size="sm"
                onPress={() => openAdd("commandcode")}
              >
                <Plus className="size-3.5" />
                Add Command Code account
              </Button>
            }
          />
        ) : (
          <Table aria-label="Command Code accounts">
            <TableHeader>
              <TableHead isRowHeader>Account</TableHead>
              <TableHead>Session token</TableHead>
              {PERIOD_COLUMNS.map((p) => (
                <TableHead key={p.id}>{p.header}</TableHead>
              ))}
              <TableHead>Enabled</TableHead>
              <TableHead className="text-right">Actions</TableHead>
            </TableHeader>
            <TableBody>
              {commandAccounts.map((a) => (
                <TableRow key={a.name}>
                  <TableCell className="font-medium">
                    <span className="flex items-center gap-2">
                      <User className="size-3.5 text-muted-foreground" />
                      {a.name}
                    </span>
                  </TableCell>
                  <TableCell className="max-w-64 truncate font-mono text-xs">
                    {}
                    {a.session_token ? (
                      <span title={a.session_token}>{a.session_token}</span>
                    ) : (
                      <Dash />
                    )}
                  </TableCell>
                  {PERIOD_COLUMNS.map((p) => (
                    <TableCell key={p.id} className="min-w-32">
                      {limitsByName.has(a.name) ? (
                        <CommandCodeUsageCell
                          limits={limitsByName.get(a.name)!}
                          period={p.id}
                        />
                      ) : (
                        <Dash />
                      )}
                    </TableCell>
                  ))}
                  <TableCell>
                    <Switch
                      aria-label={`Command Code account ${a.name} enabled`}
                      isSelected={!a.disabled}
                      onChange={(on) => setAccountEnabled(a, on)}
                      isDisabled={busy}
                    />
                  </TableCell>
                  <TableCell className="text-right">
                    <Button
                      variant="ghost"
                      size="icon"
                      aria-label={`Edit ${a.name}`}
                      onPress={() => startEdit(a)}
                      isDisabled={busy}
                    >
                      <Pencil className="size-4" />
                    </Button>
                    <Button
                      variant="ghost"
                      size="icon"
                      aria-label={`Remove ${a.name}`}
                      onPress={() => handleRemove(a.name)}
                      isDisabled={busy}
                    >
                      <Trash2 className="size-4 text-destructive" />
                    </Button>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </Section>

      <Section
        title="WorkBuddy"
        count={workbuddyAccounts.length}
        description="Signed-in or pasted auth credentials (CodeBuddy / copilot.tencent.com). All enabled accounts share one pool — requests rotate and fail over by remaining credits automatically. Tokens refresh and check in on a schedule; use Refresh to run it now."
        actions={
          <>
            <Button
              variant="outline"
              size="sm"
              onPress={handleRefreshWorkbuddy}
              isDisabled={busy || workbuddyAccounts.length === 0}
            >
              <RefreshCw className="size-3.5" />
              Refresh
            </Button>
            <Button
              variant="outline"
              size="sm"
              onPress={() => openAdd("workbuddy")}
              isDisabled={busy}
            >
              <Plus className="size-3.5" />
              {addFor === "workbuddy" ? "Close" : "Add"}
            </Button>
          </>
        }
      >
        {addFor === "workbuddy" ? addForm : null}
        {workbuddyAccounts.length === 0 ? (
          <EmptyState
            icon={Bot}
            title="No WorkBuddy accounts"
            hint="Sign in with the browser flow, read the credential the CodeBuddy desktop app wrote on this machine, or paste the auth JSON."
            action={
              <Button
                variant="outline"
                size="sm"
                onPress={() => openAdd("workbuddy")}
              >
                <Plus className="size-3.5" />
                Add WorkBuddy account
              </Button>
            }
          />
        ) : (
          <Table aria-label="WorkBuddy accounts">
            <TableHeader>
              {}
              <TableHead isRowHeader>Account</TableHead>
              <TableHead>UID</TableHead>
              <TableHead>Credits</TableHead>
              <TableHead>Enabled</TableHead>
              <TableHead className="text-right">Actions</TableHead>
            </TableHeader>
            <TableBody>
              {workbuddyAccounts.map((a) => {
                const status = a.workbuddy_uid
                  ? wbStatusByUid.get(a.workbuddy_uid)
                  : undefined
                const label =
                  a.workbuddy_nickname || a.workbuddy_uid || a.name
                return (
                  <TableRow key={a.name}>
                    <TableCell className="font-medium">
                      <span className="flex items-center gap-2">
                        <User className="size-3.5 text-muted-foreground" />
                        {a.workbuddy_nickname || <Dash />}
                      </span>
                    </TableCell>
                    <TableCell className="max-w-40 truncate font-mono text-xs">
                      {a.workbuddy_uid ? (
                        <span title={a.workbuddy_uid}>{a.workbuddy_uid}</span>
                      ) : (
                        <Dash />
                      )}
                    </TableCell>
                    <TableCell className="font-mono text-xs">
                      {status ? (
                        status.cooling ? (
                          <Badge variant="secondary" title={status.reason}>
                            cooling
                          </Badge>
                        ) : (
                          status.credits.toLocaleString()
                        )
                      ) : (
                        <Dash />
                      )}
                    </TableCell>
                    <TableCell>
                      <Switch
                        aria-label={`WorkBuddy account ${label} enabled`}
                        isSelected={!a.disabled}
                        onChange={(on) => setAccountEnabled(a, on)}
                        isDisabled={busy}
                      />
                    </TableCell>
                    <TableCell className="text-right">
                      <Button
                        variant="ghost"
                        size="icon"
                        aria-label={`Remove ${label}`}
                        onPress={() => handleRemove(a.name)}
                        isDisabled={busy}
                      >
                        <Trash2 className="size-4 text-destructive" />
                      </Button>
                    </TableCell>
                  </TableRow>
                )
              })}
            </TableBody>
          </Table>
        )}
      </Section>
    </div>
  )
}
