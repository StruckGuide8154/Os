import * as React from 'react';

export interface BadgeProps {
  children?: React.ReactNode;
  tone?: 'neutral' | 'accent' | 'success' | 'warning' | 'error';
  variant?: 'soft' | 'solid' | 'outline';
  /** Prepend a status dot. */
  dot?: boolean;
  style?: React.CSSProperties;
}

/** Compact status/label pill mapped to the semantic palette. */
export function Badge(props: BadgeProps): JSX.Element;
