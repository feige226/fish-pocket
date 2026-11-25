import { useEffect, useMemo, useRef, useState } from 'react';
import './style.css';
import { t } from './i18n.js';

const FRUIT = ['🍎', '🍊', '🍋', '🍉', '🍇', '🍓', '🍑', '🍍', '🥝', '🍌', '🍒', '🫐'];
const PAIRS = 6;
const BEST_KEY = 'fruit-flip.best';

function deal() {
  const fruit = [...FRUIT].sort(() => Math.random() - 0.5).slice(0, PAIRS);
  const cards = [...fruit, ...fruit].map((face, index) => ({ id: index, face, matched: false }));
  for (let i = cards.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [cards[i], cards[j]] = [cards[j], cards[i]];
  }
  return cards;
}

/// The fewest moves so far. An earlier version kept one per level: its first level was this board.
function loadBest() {
  try {
    const saved = JSON.parse(localStorage.getItem(BEST_KEY));
    if (typeof saved === 'number') return saved;
    return saved?.[0]?.moves ?? null;
  } catch {
    return null;
  }
}

/// Three stars for close to perfect play, fewer as moves pile up.
const stars = (moves) => (moves <= PAIRS * 1.5 ? 3 : moves <= PAIRS * 2.4 ? 2 : 1);

export default function App() {
  // A new round is a new deck: the cards are dealt in again.
  const [round, setRound] = useState(0);
  const [cards, setCards] = useState(deal);
  const [open, setShown] = useState([]);
  // Two quick taps land before a render: the second must see the first.
  const openRef = useRef([]);
  const setOpen = (next) => {
    openRef.current = next;
    setShown(next);
  };
  const [miss, setMiss] = useState([]);
  const [moves, setMoves] = useState(0);
  const [best, setBest] = useState(loadBest);
  const [result, setResult] = useState(null);
  const busy = useRef(false);
  const timers = useRef([]);
  const later = (run, delay) => timers.current.push(setTimeout(run, delay));

  useEffect(() => () => timers.current.forEach(clearTimeout), []);

  const start = () => {
    timers.current.forEach(clearTimeout);
    timers.current = [];
    busy.current = false;
    setCards(deal());
    setOpen([]);
    setMiss([]);
    setMoves(0);
    setResult(null);
    setRound((count) => count + 1);
  };

  const flip = (index) => {
    const current = openRef.current;
    if (busy.current || current.includes(index) || cards[index].matched) return;
    const next = [...current, index];
    setOpen(next);
    if (next.length < 2) return;

    const total = moves + 1;
    setMoves(total);
    const [a, b] = next;
    busy.current = true;
    if (cards[a].face === cards[b].face) {
      later(() => {
        const updated = cards.map((card, i) => (i === a || i === b ? { ...card, matched: true } : card));
        setCards(updated);
        setOpen([]);
        busy.current = false;
        if (updated.every((card) => card.matched)) later(() => finish(total), 520);
      }, 380);
    } else {
      later(() => setMiss(next), 420);
      later(() => {
        setMiss([]);
        setOpen([]);
        busy.current = false;
      }, 900);
    }
  };

  const finish = (total) => {
    const record = best == null || total < best;
    if (record) {
      setBest(total);
      localStorage.setItem(BEST_KEY, JSON.stringify(total));
    }
    setResult({ moves: total, record });
  };

  const found = cards.filter((card) => card.matched).length / 2;

  return (
    <main className="table">
      <header className="score">
        <div>
          <span>{t.moves}</span>
          <b key={moves} className={moves ? 'tick' : ''}>{moves}</b>
        </div>
        <ol className="found" aria-label={`${found}/${PAIRS}`}>
          {Array.from({ length: PAIRS }, (_, n) => <li key={n} className={n < found ? 'on' : ''} />)}
        </ol>
        <div>
          <span>{t.best}</span>
          <b>{best ?? '–'}</b>
        </div>
      </header>

      <div className="board" key={round}>
        {cards.map((card, index) => {
          const up = card.matched || open.includes(index);
          return (
            <button
              key={card.id}
              className={`card${up ? ' up' : ''}${card.matched ? ' matched' : ''}${miss.includes(index) ? ' miss' : ''}`}
              style={{ '--order': index }}
              onPointerDown={() => flip(index)}
              aria-label={up ? card.face : t.hidden}
            >
              <span className="card-inner">
                <span className="card-back" aria-hidden="true" />
                <span className="card-face" aria-hidden="true">{card.face}</span>
              </span>
            </button>
          );
        })}
      </div>

      <footer className="foot">
        {moves === 0 ? (
          <p className="hint">{t.hint}</p>
        ) : (
          <button className="restart" onClick={start}>
            <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 12a8 8 0 1 0 2.4-5.7M4 4v4.5h4.5" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" fill="none" /></svg>
            {t.restart}
          </button>
        )}
      </footer>

      {result && <Won result={result} fruit={cards.map((card) => card.face)} onAgain={start} />}
    </main>
  );
}

/// The round's end: fruit rains down behind a card with the score.
function Won({ result, fruit, onAgain }) {
  const rain = useMemo(
    () => Array.from({ length: 18 }, (_, n) => ({
      face: fruit[n % fruit.length],
      left: 4 + ((n * 37) % 92),
      delay: (n % 9) * 0.12,
      length: 2.2 + ((n * 7) % 10) / 8,
      size: 26 + ((n * 13) % 22),
    })),
    [],
  );
  const earned = stars(result.moves);
  return (
    <div className="won" role="dialog" aria-label={t.won}>
      <div className="rain" aria-hidden="true">
        {rain.map((drop, n) => (
          <span key={n} style={{ left: `${drop.left}%`, fontSize: drop.size, animationDelay: `${drop.delay}s`, animationDuration: `${drop.length}s` }}>{drop.face}</span>
        ))}
      </div>
      <div className="won-card">
        <div className="stars" aria-label={`${earned}/3`}>
          {[1, 2, 3].map((n) => (
            <svg key={n} viewBox="0 0 24 24" className={n <= earned ? 'lit' : ''} style={{ '--order': n }} aria-hidden="true">
              <path d="M12 2.6l2.8 5.9 6.4.8-4.7 4.4 1.2 6.4L12 17l-5.7 3.1 1.2-6.4-4.7-4.4 6.4-.8z" strokeLinejoin="round" />
            </svg>
          ))}
        </div>
        <h2>{t.won}</h2>
        <p className="won-line">{t.inMoves(result.moves)}</p>
        {result.record && <p className="won-best">{t.newBest}</p>}
        <button className="again" onClick={onAgain}>{t.again}</button>
      </div>
    </div>
  );
}
