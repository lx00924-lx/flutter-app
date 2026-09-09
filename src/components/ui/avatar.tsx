import * as React from "react"
import { cn } from "@/lib/utils"

const Avatar = React.forwardRef<
  HTMLDivElement,
  React.HTMLAttributes<HTMLDivElement>
>(({ className, ...props }, ref) => (
  <div
    ref={ref}
    className={cn(
      "relative h-10 w-10 flex-shrink-0 overflow-hidden rounded-sm",
      className
    )}
    {...props}
  >
    {props.children}
  </div>
))
Avatar.displayName = "Avatar"

const AvatarImage = React.forwardRef<
  HTMLImageElement,
  React.ImgHTMLAttributes<HTMLImageElement>
>(({ className, ...props }, ref) => (
  <img
    ref={ref}
    className={cn("aspect-square h-full w-full rounded-sm", className)}
    {...props}
  />
))
AvatarImage.displayName = "AvatarImage"

const AvatarFallback = React.forwardRef<
  HTMLDivElement,
  React.HTMLAttributes<HTMLDivElement>
>(({ className, ...props }, ref) => (
  <div
    ref={ref}
    className={cn(
      "flex h-full w-full items-center justify-center rounded-sm bg-muted",
      className
    )}
    {...props}
  >
    {props.children}
  </div>
))
AvatarFallback.displayName = "AvatarFallback"

export { Avatar, AvatarImage, AvatarFallback }