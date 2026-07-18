import * as React from 'react';

export interface InputProps {
  value?: string;
  defaultValue?: string;
  placeholder?: string;
  type?: string;
  size?: 'sm' | 'md' | 'lg';
  /** Leading icon node. */
  icon?: React.ReactNode;
  /** Trailing node (icon, kbd hint, clear button). */
  trailing?: React.ReactNode;
  /** Error state — red border + soft glow. */
  invalid?: boolean;
  disabled?: boolean;
  /** Fill container width. @default true */
  block?: boolean;
  onChange?: (e: React.ChangeEvent<HTMLInputElement>) => void;
  style?: React.CSSProperties;
}

/** Inset text field; focus lights the neon ring. */
export function Input(props: InputProps): JSX.Element;
