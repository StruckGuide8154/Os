import * as React from 'react';

export interface DockItemModel {
  id: string;
  /** Icon node (e.g. a Lucide <i data-lucide="…" />). */
  icon: React.ReactNode;
  label: string;
  /** Highlighted/focused app. */
  active?: boolean;
  /** Shows the running dot under the tile. */
  running?: boolean;
}

export interface DockProps {
  items?: DockItemModel[];
  onItemClick?: (id: string) => void;
  style?: React.CSSProperties;
}

/**
 * The redesigned taskbar — a floating glass dock of app tiles with
 * hover-lift, active tint and a running indicator dot.
 * @startingPoint section="Shell" subtitle="Floating glass taskbar / dock" viewport="700x150"
 */
export function Dock(props: DockProps): JSX.Element;
