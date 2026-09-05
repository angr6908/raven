import * as React from "react"

import {
  composeRenderProps,
  Switch as SwitchPrimitive,
  type SwitchProps as SwitchPrimitiveProps,
} from "react-aria-components"

import { cn } from "@/lib/utils"

function Switch({
  className,
  ...props
}: SwitchPrimitiveProps & { children?: React.ReactNode }) {
  return (
    <SwitchPrimitive
      data-slot="switch"
      className={composeRenderProps(className, (className) =>
        cn(
          "group inline-flex w-fit items-center gap-2 text-xs font-medium outline-none disabled:cursor-not-allowed disabled:opacity-50",
          className
        )
      )}
      {...props}
    >
      {composeRenderProps(
        props.children,
        (children, { isSelected }) => (
          <>
            <span
              data-slot="switch-track"
              className={cn(
                "relative inline-flex h-5 w-9 shrink-0 items-center rounded-full border border-transparent p-0.5 outline-none transition-colors group-data-[pressed]/switch:cursor-wait",
                isSelected
                  ? "bg-primary"
                  : "bg-muted-foreground/30 group-data-[disabled]/switch:bg-muted-foreground/20"
              )}
            >
              <span
                data-slot="switch-thumb"
                className={cn(
                  "pointer-events-none inline-block size-4 translate-x-0 rounded-full bg-background shadow-sm ring-0 transition-transform",
                  isSelected && "translate-x-4"
                )}
              />
            </span>
            {children}
          </>
        )
      )}
    </SwitchPrimitive>
  )
}

export { Switch }
