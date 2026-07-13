import * as React from 'react';

export interface CheckboxProps {
  checked?: boolean;
  indeterminate?: boolean;
  disabled?: boolean;
  label?: string;
  onChange?: (next: boolean) => void;
  style?: React.CSSProperties;
}

/** Square checkbox with accent fill; supports an indeterminate dash. */
export function Checkbox(props: CheckboxProps): JSX.Element;
