import * as React from 'react';

export interface SliderProps {
  value?: number;
  min?: number;
  max?: number;
  step?: number;
  disabled?: boolean;
  onChange?: (next: number) => void;
  style?: React.CSSProperties;
}

/** Horizontal range slider; the filled portion uses the accent gradient. */
export function Slider(props: SliderProps): JSX.Element;
