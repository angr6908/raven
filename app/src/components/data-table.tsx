import * as React from "react"
import { Fragment } from "react"
import {
  ArrowDown,
  ArrowUp,
  ChevronLeft,
  ChevronRight,
  ChevronsUpDown,
  Search,
} from "lucide-react"
import {
  type CellData,
  type ColumnDef,
  type ColumnFiltersState,
  type OnChangeFn,
  type PaginationState,
  type ReactTable,
  type Row,
  type RowData,
  type SortingState,
  type TableFeatures,
  useTable,
} from "@tanstack/react-table"

import { features } from "@/lib/data-table-features"
import { cn } from "@/lib/utils"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select"
import {
  Table,
  TableBody,
  TableCell,
  TableFooter,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"

export type DataTableFeatures = typeof features

declare module "@tanstack/react-table" {
  interface ColumnMeta<
    TFeatures extends TableFeatures,
    TData extends RowData,
    TValue extends CellData = CellData
  > {
    align?: "left" | "right"
    cellClassName?: string
  }
}

export interface DataTableProps<TData extends RowData> {
  columns: ColumnDef<DataTableFeatures, TData>[]
  data: TData[]
  searchKey?: string
  searchPlaceholder?: string
  tableLabel?: string
  renderExpandedRow?: (
    row: Row<DataTableFeatures, TData>
  ) => Record<string, React.ReactNode> | undefined
  getRowCanExpand?: (row: Row<DataTableFeatures, TData>) => boolean
  getIsRowExpanded?: (row: Row<DataTableFeatures, TData>) => boolean
  footer?: React.ReactNode
  hidePaginationOnSinglePage?: boolean
  enablePagination?: boolean
  searchValue?: string
  onSearchChange?: (value: string) => void
  columnFilters?: ColumnFiltersState
  onColumnFiltersChange?: (filters: ColumnFiltersState) => void
}

const PAGE_SIZES = [15, 30, 50] as const

export function DataTableSearch({
  value,
  onChange,
  placeholder = "Search…",
  className,
}: {
  value: string
  onChange: (value: string) => void
  placeholder?: string
  className?: string
}) {
  return (
    <div className={cn("relative w-full max-w-64", className)}>
      <Search className="absolute top-1/2 left-2.5 size-3.5 -translate-y-1/2 text-muted-foreground" />
      <Input
        value={value}
        onChange={(e) => onChange(e.target.value)}
        placeholder={placeholder}
        className="pl-8"
        aria-label={placeholder}
      />
    </div>
  )
}

export function DataTable<TData extends RowData>({
  columns,
  data,
  searchKey,
  searchPlaceholder = "Search…",
  tableLabel = "Data table",
  renderExpandedRow,
  getRowCanExpand,
  getIsRowExpanded,
  footer,
  hidePaginationOnSinglePage,
  enablePagination = true,
  searchValue,
  onSearchChange,
  columnFilters: columnFiltersProp,
  onColumnFiltersChange: onColumnFiltersChangeProp,
}: DataTableProps<TData>) {
  const [sorting, setSorting] = React.useState<SortingState>([])
  const [internalFilters, setColumnFilters] = React.useState<ColumnFiltersState>([])
  const columnFilters = columnFiltersProp ?? internalFilters
  const [pagination, setPagination] = React.useState<PaginationState>({
    pageIndex: 0,
    pageSize: PAGE_SIZES[0],
  })
  const effectivePagination = enablePagination
    ? pagination
    : { pageIndex: 0, pageSize: Number.MAX_SAFE_INTEGER }

  const handleFiltersChange: OnChangeFn<ColumnFiltersState> = (updater) => {
    const next = typeof updater === "function" ? updater(columnFilters) : updater
    if (onColumnFiltersChangeProp) onColumnFiltersChangeProp(next)
    else setColumnFilters(next)
  }

  const table = useTable({
    columns,
    data,
    features,
    state: { sorting, columnFilters, pagination: effectivePagination },
    getRowCanExpand,
    getIsRowExpanded,
    onSortingChange: setSorting,
    onColumnFiltersChange: handleFiltersChange,
    onPaginationChange: setPagination,
  })

  const searchColumn = searchKey ? table.getColumn(searchKey) : undefined

  React.useEffect(() => {
    if (onSearchChange && searchColumn) {
      searchColumn.setFilterValue(searchValue || undefined)
    }
  }, [searchValue, onSearchChange, searchColumn])

  const renderRow = (row: Row<DataTableFeatures, TData>) => (
    <Fragment key={row.id}>
      <TableRow id={row.id}>
        {row.getVisibleCells().map((cell) => (
          <TableCell
            key={cell.id}
            className={cn(
              cell.column.columnDef.meta?.align === "right" &&
                "text-right tabular-nums",
              cell.column.columnDef.meta?.cellClassName
            )}
          >
            <table.FlexRender cell={cell} />
          </TableCell>
        ))}
      </TableRow>
      {renderExpandedRow && row.getCanExpand() && row.getIsExpanded() ? (
        <TableRow id={`${row.id}-detail`} className="border-b bg-muted/40">
          {row.getVisibleCells().map((cell) => {
            const detail = renderExpandedRow(row)?.[cell.column.id]
            return (
              <TableCell
                key={cell.id}
                className={cn(
                  cell.column.columnDef.meta?.align === "right" &&
                    "text-right tabular-nums",
                  cell.column.columnDef.meta?.cellClassName,
                  "whitespace-normal",
                  !detail && "p-0"
                )}
              >
                {detail}
              </TableCell>
            )
          })}
        </TableRow>
      ) : null}
    </Fragment>
  )

  return (
    <div className="w-full min-w-0 space-y-2">
      {searchColumn && !onSearchChange ? (
        <div className="flex justify-end">
          <DataTableSearch
            value={(searchColumn.getFilterValue() as string) ?? ""}
            onChange={(value) => searchColumn.setFilterValue(value)}
            placeholder={searchPlaceholder}
          />
        </div>
      ) : null}

      <div className="overflow-hidden rounded-none border">
        <Table
          aria-label={tableLabel}
          sortDescriptor={
            sorting.length
              ? {
                  column: sorting[0].id,
                  direction: sorting[0].desc ? "descending" : "ascending",
                }
              : undefined
          }
          onSortChange={(sortDescriptor) => {
            table.setSorting([
              {
                id: "" + sortDescriptor.column,
                desc: sortDescriptor.direction === "descending",
              },
            ]);
          }}
        >
          <TableHeader>
            {table.getFlatHeaders().map((header) => (
              <TableHead
                key={header.id}
                id={header.id}
                isRowHeader={header.index === 0}
                className={cn(
                  header.column.columnDef.meta?.align === "right" && "text-right",
                  header.column.columnDef.meta?.cellClassName
                )}
              >
                {header.isPlaceholder ? null : header.column.getCanSort() ? (
                  <button
                    type="button"
                    onClick={() => header.column.toggleSorting()}
                    className="inline-flex items-center gap-1 hover:text-foreground"
                  >
                    <table.FlexRender header={header} />
                    {header.column.getIsSorted() === "asc" ? (
                      <ArrowUp className="size-3 shrink-0" />
                    ) : header.column.getIsSorted() === "desc" ? (
                      <ArrowDown className="size-3 shrink-0" />
                    ) : (
                      <ChevronsUpDown className="size-3 shrink-0 opacity-60" />
                    )}
                  </button>
                ) : (
                  <table.FlexRender header={header} />
                )}
              </TableHead>
            ))}
          </TableHeader>
          <TableBody renderEmptyState={() => "No results."}>
            {table.getRowModel().rows.map(renderRow)}
          </TableBody>
          {footer ? <TableFooter>{footer}</TableFooter> : null}
        </Table>
      </div>

      {enablePagination &&
      !(hidePaginationOnSinglePage &&
        table.getFilteredRowModel().rows.length <= PAGE_SIZES[0]) ? (
        <TablePagination table={table} />
      ) : null}
    </div>
  )
}

function TablePagination<TData extends RowData>({
  table,
}: {
  table: ReactTable<DataTableFeatures, TData>
}) {
  const { pageIndex, pageSize } = table.state.pagination
  const total = table.getFilteredRowModel().rows.length
  const pages = Math.max(1, Math.ceil(total / pageSize))

  const pageItems = buildPageItems(pageIndex, pages)

  return (
    <div className="flex flex-wrap items-center justify-between gap-2 text-sm text-muted-foreground">
      <span>{total} row{total === 1 ? "" : "s"}</span>
      <div className="flex items-center gap-2">
        <Select
          aria-label="Rows per page"
          selectedKey={String(pageSize)}
          onSelectionChange={(key) => table.setPageSize(Number(key))}
          className="w-24"
        >
          <SelectTrigger size="sm">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {PAGE_SIZES.map((n) => (
              <SelectItem key={n} id={String(n)}>
                {n} / page
              </SelectItem>
            ))}
          </SelectContent>
        </Select>

        <div className="flex items-center gap-1">
          <Button
            variant="outline"
            size="sm"
            className="h-7 gap-1 px-2 text-xs transition-none"
            isDisabled={!table.getCanPreviousPage()}
            onPress={() => table.previousPage()}
          >
            <ChevronLeft className="size-3" />
            Prev
          </Button>

          {pageItems.map((item, i) =>
            item === "…" ? (
              <span key={`gap-${i}`} className="px-0.5 text-xs text-muted-foreground">
                …
              </span>
            ) : (
              <Button
                key={item}
                variant={item - 1 === pageIndex ? "default" : "outline"}
                size="sm"
                className="h-7 min-w-7 px-1 text-xs tabular-nums transition-none"
                aria-label={`Page ${item}`}
                aria-current={item - 1 === pageIndex ? "page" : undefined}
                onPress={() => table.setPageIndex(item - 1)}
              >
                {item}
              </Button>
            )
          )}

          <Button
            variant="outline"
            size="sm"
            className="h-7 gap-1 px-2 text-xs transition-none"
            isDisabled={!table.getCanNextPage()}
            onPress={() => table.nextPage()}
          >
            Next
            <ChevronRight className="size-3" />
          </Button>
        </div>
      </div>
    </div>
  )
}

function buildPageItems(pageIndex: number, pages: number): (number | "…")[] {
  if (pages <= 7) {
    return Array.from({ length: pages }, (_, i) => i + 1)
  }
  const current = pageIndex + 1
  const items = new Set<number>([1, pages, current - 1, current, current + 1])
  const sorted = [...items].filter((n) => n >= 1 && n <= pages).sort((a, b) => a - b)

  const out: (number | "…")[] = []
  let prev = 0
  for (const n of sorted) {
    if (n - prev > 1) out.push("…")
    out.push(n)
    prev = n
  }
  return out
}