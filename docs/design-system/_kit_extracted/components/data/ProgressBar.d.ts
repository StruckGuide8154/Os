import * as React from 'react';

export interface ProgressBarProps {
  /** 0–100; ignored when indeterminate. */
  value?: number;
  indeterminate?: boolean;
  height?: number;
  tone?: 'accent' | 'success' | 'warning' | 'error';
  style?: React.CSSProperties;
}

/** Linear progress track with accent-gradient fill or sweeping shimmer. */
export function ProgressBar(props: ProgressBarProps): JSX.Element;
