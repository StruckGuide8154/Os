import * as React from 'react';

export interface IconButtonProps {
  /** Icon node (e.g. a Lucide <i data-lucide="x" />). */
  icon: React.ReactNode;
  size?: 'sm' | 'md' | 'lg';
  tone?: 'neutral' | 'accent' | 'danger';
  /** Sticky toggled/selected state. */
  active?: boolean;
  disabled?: boolean;
  /** Accessible label — strongly recommended for icon-only buttons. */
  label?: string;
  onClick?: (e: React.MouseEvent<HTMLButtonElement>) => void;
  style?: React.CSSProperties;
}

/** Square icon-only control for toolbars, window titlebars and the dock. */
export function IconButton(props: IconButtonProps): JSX.Element;
