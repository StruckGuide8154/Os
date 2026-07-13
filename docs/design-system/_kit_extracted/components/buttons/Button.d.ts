import * as React from 'react';

export interface ButtonProps {
  children?: React.ReactNode;
  /** Visual emphasis. @default 'secondary' */
  variant?: 'primary' | 'secondary' | 'ghost' | 'danger';
  /** Control height. @default 'md' */
  size?: 'sm' | 'md' | 'lg';
  /** Leading icon node. */
  icon?: React.ReactNode;
  /** Trailing icon node. */
  trailingIcon?: React.ReactNode;
  disabled?: boolean;
  /** Stretch to fill container width. */
  block?: boolean;
  type?: 'button' | 'submit' | 'reset';
  onClick?: (e: React.MouseEvent<HTMLButtonElement>) => void;
  style?: React.CSSProperties;
}

/**
 * Grit primary control. The `primary` variant carries the neon
 * accent gradient + glow; use exactly one per view as the main action.
 *
 * @startingPoint section="Controls" subtitle="Accent, secondary, ghost & danger buttons" viewport="700x200"
 */
export function Button(props: ButtonProps): JSX.Element;
