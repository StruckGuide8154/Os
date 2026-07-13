import * as React from 'react';

export interface TabItemModel {
  id: string;
  label: string;
  icon?: React.ReactNode;
}

export interface TabsProps {
  items?: TabItemModel[];
  /** Selected tab id. */
  value?: string;
  onChange?: (id: string) => void;
  size?: 'sm' | 'md';
  style?: React.CSSProperties;
}

/** Segmented control / tab switcher with a raised selected pill. */
export function Tabs(props: TabsProps): JSX.Element;
