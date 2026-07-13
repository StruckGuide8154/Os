import * as React from 'react';

export interface SwitchProps {
  checked?: boolean;
  disabled?: boolean;
  size?: 'sm' | 'md';
  /** Optional text label rendered to the right of the track. */
  label?: string;
  onChange?: (next: boolean) => void;
  style?: React.CSSProperties;
}

/** Pill toggle; the on-state fills with the accent gradient + glow. */
export function Switch(props: SwitchProps): JSX.Element;
