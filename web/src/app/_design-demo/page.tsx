// UI primitives demo — preserved here for reference.
// This folder is prefixed with `_` so Next.js does NOT route to it.
// To view, copy the file into `app/page.tsx` or a real route temporarily.
import { BookOpen, Zap, ArrowRight } from "lucide-react";
import { Btn, Chip, Card, Icon, Sparkline, SectionLabel } from "@/components/ui";

export default function DesignDemo() {
  return (
    <div className="min-h-screen bg-bg-warm p-10 flex flex-col gap-10 max-w-2xl mx-auto">
      <h1 className="ds-h1">Codex UI Primitives</h1>

      {/* Btn */}
      <section className="flex flex-col gap-3">
        <SectionLabel>Buttons</SectionLabel>
        <div className="flex flex-wrap gap-3">
          <Btn kind="primary">Primary</Btn>
          <Btn kind="secondary">Secondary</Btn>
          <Btn kind="soft">Soft</Btn>
          <Btn kind="ghost">Ghost</Btn>
        </div>
        <div className="flex flex-wrap gap-3">
          <Btn kind="primary" size="sm">Small Primary</Btn>
          <Btn kind="secondary" size="sm">Small Secondary</Btn>
          <Btn kind="primary" pill icon={<Icon as={Zap} size={14} />}>
            With Icon
          </Btn>
          <Btn kind="secondary" iconRight={<Icon as={ArrowRight} size={14} />}>
            Icon Right
          </Btn>
        </div>
        <div className="flex flex-wrap gap-3">
          <Btn kind="primary" disabled>Disabled</Btn>
        </div>
      </section>

      {/* Chip */}
      <section className="flex flex-col gap-3">
        <SectionLabel>Chips</SectionLabel>
        <div className="flex flex-wrap gap-2">
          <Chip tone="default">Default</Chip>
          <Chip tone="accent">Accent</Chip>
          <Chip tone="success">Success</Chip>
          <Chip tone="warning">Warning</Chip>
          <Chip tone="error">Error</Chip>
          <Chip tone="ghost">Ghost</Chip>
          <Chip tone="accent">Interactive</Chip>
        </div>
      </section>

      {/* Card */}
      <section className="flex flex-col gap-3">
        <SectionLabel>Cards</SectionLabel>
        <div className="flex gap-4">
          <Card className="flex-1">
            <p className="ds-body-md">Default card with border and white background.</p>
          </Card>
          <Card sunken className="flex-1">
            <p className="ds-body-md">Sunken card with surface-sunken background.</p>
          </Card>
        </div>
      </section>

      {/* Icon */}
      <section className="flex flex-col gap-3">
        <SectionLabel>Icons</SectionLabel>
        <div className="flex gap-4 items-center">
          <Icon as={BookOpen} size={20} className="text-accent" />
          <Icon as={Zap} size={20} className="text-warning" />
          <Icon as={ArrowRight} size={20} className="text-fg-muted" />
        </div>
      </section>

      {/* Sparkline */}
      <section className="flex flex-col gap-3">
        <SectionLabel>Sparklines</SectionLabel>
        <div className="flex gap-6 items-end">
          <Sparkline values={[2, 5, 3, 8, 6, 9, 4]} />
          <Sparkline values={[2, 5, 3, 8, 6, 9, 4]} fill />
          <Sparkline values={[1, 1, 2, 3, 5, 8, 13]} color="var(--success)" fill w={100} h={32} />
        </div>
      </section>
    </div>
  );
}
