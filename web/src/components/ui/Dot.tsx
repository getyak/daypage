interface DotProps {
  opacity?: number;
  className?: string;
}

export function Dot({ opacity = 0.45, className }: DotProps) {
  return (
    <span
      aria-hidden="true"
      className={className}
      style={{
        display: "inline-block",
        width: 3,
        height: 3,
        borderRadius: "50%",
        background: "currentColor",
        opacity,
        flexShrink: 0,
      }}
    />
  );
}
