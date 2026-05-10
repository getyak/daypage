import { type LucideIcon } from "lucide-react";

interface IconProps {
  as: LucideIcon;
  size?: number;
  className?: string;
}

export function Icon({ as: LucideComp, size = 16, className = "" }: IconProps) {
  return <LucideComp size={size} className={className} aria-hidden="true" />;
}
