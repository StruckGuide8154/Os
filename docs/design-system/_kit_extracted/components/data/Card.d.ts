import * as React from 'react';

export interface CardProps {
  children?: React.ReactNode;
  padding?: 'none' | 'sm' | 'md' | 'lg';
  /** Hover lift + deepened shadow; pairs with onClick. */
  interactive?: boolean;
  /** Neon edge + glow for featured/selected cards. */
  glow?: boolean;
  onClick?: (e: React.MouseEvent<HTMLDivElement>) => void;
  style?: React.CSSProperties;
}

/**
 * Base surface container — panels, list items, tiles.
 * @startingPoint section="Surfaces" subtitle="Panel surface with hover lift & neon variant" viewport="700x220"
 */
export function Card(props: CardProps): JSX.Element;
