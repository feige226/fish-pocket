import { useEffect, useMemo, useRef, useState } from 'react';
import { flushSync } from 'react-dom';
import './style.css';
import { locale, t, unit } from './i18n.js';

const KEY = 'days.v1';
const PICK_KEY = 'days.front';
const COLORS = ['#4F6BFF', '#FF6B4A', '#F59E0B', '#10B981', '#8B5CF6', '#0EA5B7'];
const DAY = 86400000;

const today = () => {
  const now = new Date();
  return new Date(now.getFullYear(), now.getMonth(), now.getDate());
};
const iso = (date) => `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
const parse = (text) => {
  const [y, m, d] = text.split('-').map(Number);
  return new Date(y, m - 1, d);
};

/// Days from today: positive ahead, negative behind.
const offset = (event) => Math.round((parse(event.date) - today()) / DAY);

const longDate = new Intl.DateTimeFormat(locale, { year: 'numeric', month: 'long', day: 'numeric', weekday: 'short' });
const monthName = new Intl.DateTimeFormat(locale, { month: 'short' });

function seed() {
  const now = today();
  const saturday = new Date(now.getFullYear(), now.getMonth(), now.getDate() + ((6 - now.getDay() + 7) % 7));
  return [
    { id: 'new-year', title: t.seedNewYear, date: `${now.getFullYear() + 1}-01-01`, color: COLORS[0] },
    { id: 'weekend', title: t.seedWeekend, date: iso(saturday), color: COLORS[1] },
    { id: 'this-year', title: t.seedThisYear, date: `${now.getFullYear()}-01-01`, color: COLORS[3] },
  ];
}

/// What an earlier version saved still opens: a date that repeated every year becomes its next one.
function load() {
  try {
    const saved = JSON.parse(localStorage.getItem(KEY));
    if (Array.isArray(saved)) {
      return saved.filter((event) => event && event.id && event.date).map(({ id, title, date, color, yearly }) => {
        if (yearly) {
          const now = today();
          const day = parse(date);
          const next = new Date(now.getFullYear(), day.getMonth(), day.getDate());
          if (next < now) next.setFullYear(now.getFullYear() + 1);
          date = iso(next);
        }
        return { id: String(id), title: title || '', date, color: color || COLORS[0] };
      });
    }
  } catch {}
  return seed();
}

/// A change the page animates between: the card in front and the rows trade places.
function morph(change) {
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
  if (!document.startViewTransition || reduced) return change();
  document.startViewTransition(() => flushSync(change));
}

export default function App() {
  const [events, setEvents] = useState(load);
  // The first time, the new year: a count worth a large card.
  const [front, setFront] = useState(() => localStorage.getItem(PICK_KEY) || 'new-year');
  const [editing, setEditing] = useState(null);

  useEffect(() => {
    localStorage.setItem(KEY, JSON.stringify(events));
  }, [events]);
  useEffect(() => {
    if (front) localStorage.setItem(PICK_KEY, front);
  }, [front]);

  // Ahead soonest first, then behind most recent first.
  const sorted = useMemo(() => {
    return [...events].sort((a, b) => {
      const x = offset(a), y = offset(b);
      if ((x >= 0) !== (y >= 0)) return x >= 0 ? -1 : 1;
      return Math.abs(x) - Math.abs(y);
    });
  }, [events]);
  const hero = sorted.find((event) => event.id === front) || sorted.find((event) => offset(event) > 0) || sorted[0];
  const rest = sorted.filter((event) => event !== hero);

  const save = (event) => {
    setEditing(null);
    morph(() => {
      setEvents((list) => [...list.filter((item) => item.id !== event.id), event]);
      setFront(event.id);
    });
  };
  const remove = (id) => {
    setEditing(null);
    morph(() => setEvents((list) => list.filter((item) => item.id !== id)));
  };
  const nextColor = () => COLORS.find((color) => !events.some((event) => event.color === color)) || COLORS[events.length % COLORS.length];

  return (
    <main className="page">
      {hero ? (
        <Hero key={hero.id} event={hero} onEdit={() => setEditing(hero)} />
      ) : (
        <div className="empty">
          <span className="empty-leaf" aria-hidden="true"><b>?</b></span>
          <p>{t.empty}</p>
        </div>
      )}

      {rest.length > 0 && (
        <ul className="rows">
          {rest.map((event) => (
            <li key={event.id}>
              <Row event={event} onPick={() => morph(() => setFront(event.id))} />
            </li>
          ))}
        </ul>
      )}

      <button className="add" onClick={() => setEditing({ color: nextColor() })}>
        <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 5v14M5 12h14" stroke="currentColor" strokeWidth="2.6" strokeLinecap="round" fill="none" /></svg>
        {t.add}
      </button>

      {editing && <Editor event={editing} onSave={save} onRemove={remove} onClose={() => setEditing(null)} />}
    </main>
  );
}

/// The number, run up from zero when the card comes to the front.
function useCountUp(value) {
  const [shown, setShown] = useState(() => (matchMedia('(prefers-reduced-motion: reduce)').matches ? value : 0));
  useEffect(() => {
    if (matchMedia('(prefers-reduced-motion: reduce)').matches) return setShown(value);
    const started = performance.now();
    const length = Math.min(900, 380 + value * 6);
    let frame;
    const step = (now) => {
      const progress = Math.min(1, (now - started) / length);
      setShown(Math.round(value * (1 - Math.pow(1 - progress, 4))));
      if (progress < 1) frame = requestAnimationFrame(step);
    };
    frame = requestAnimationFrame(step);
    return () => cancelAnimationFrame(frame);
  }, [value]);
  return shown;
}

/// What a card says about its day, the same on the front card and in the editor's preview.
function Count({ days, number }) {
  if (days === 0) return <span className="count-today">{t.today}</span>;
  return (
    <>
      <span className="count-lead">{days > 0 ? t.future : t.past}</span>
      <span className="count-number">
        <b>{number ?? Math.abs(days)}</b>
        <span>{unit(Math.abs(days))}</span>
      </span>
    </>
  );
}

/// The day in front: its count, large, on a card of its own colour.
function Hero({ event, onEdit }) {
  const days = offset(event);
  const number = useCountUp(Math.abs(days));
  return (
    <section className="hero" style={{ '--tone': event.color, viewTransitionName: `day-${event.id}` }}>
      <span className="hero-rings" aria-hidden="true" />
      <header className="hero-head">
        <h1>{event.title}</h1>
        <button className="hero-edit" onClick={onEdit} aria-label={t.editTitle}>
          <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12h.01M12 12h.01M19 12h.01" stroke="currentColor" strokeWidth="3.2" strokeLinecap="round" fill="none" /></svg>
        </button>
      </header>
      <div className="hero-count">
        <Count days={days} number={number} />
      </div>
      <p className="hero-date">{longDate.format(parse(event.date))}</p>
    </section>
  );
}

/// A day waiting below: tap it and it comes to the front.
function Row({ event, onPick }) {
  const days = offset(event);
  const date = parse(event.date);
  return (
    <button className="row" style={{ '--tone': event.color, viewTransitionName: `day-${event.id}` }} onClick={onPick}>
      <span className="leaf" aria-hidden="true">
        <i>{monthName.format(date)}</i>
        <b>{date.getDate()}</b>
      </span>
      <span className="row-title">{event.title}</span>
      <span className="row-count">
        {days === 0 ? (
          <b>{t.todayShort}</b>
        ) : (
          <>
            <b>{Math.abs(days)}</b>
            <span>{t.rel(Math.abs(days), days > 0)}</span>
          </>
        )}
      </span>
    </button>
  );
}

/// A sheet from the bottom, with the card as it will look. It can be pulled down to close.
function Editor({ event, onSave, onRemove, onClose }) {
  const isNew = !event.id;
  const [title, setTitle] = useState(event.title || '');
  const [date, setDate] = useState(event.date || iso(today()));
  const [shown, setShown] = useState(false);
  const [pull, setPull] = useState(0);
  const [sure, setSure] = useState(false);
  const grab = useRef(null);

  useEffect(() => {
    const frame = requestAnimationFrame(() => setShown(true));
    return () => cancelAnimationFrame(frame);
  }, []);
  useEffect(() => {
    if (!sure) return;
    const timer = setTimeout(() => setSure(false), 3000);
    return () => clearTimeout(timer);
  }, [sure]);

  // Out the way it came in, then gone.
  const leave = (then) => {
    setShown(false);
    setTimeout(then, 260);
  };
  const close = () => leave(onClose);

  const valid = title.trim() && date;
  const submit = (e) => {
    e.preventDefault();
    if (!valid) return;
    const saved = { id: event.id || String(Date.now()), title: title.trim(), date, color: event.color };
    leave(() => onSave(saved));
  };

  const down = (e) => {
    grab.current = e.clientY;
    e.currentTarget.setPointerCapture(e.pointerId);
  };
  const move = (e) => {
    if (grab.current != null) setPull(Math.max(0, e.clientY - grab.current));
  };
  const up = () => {
    if (grab.current == null) return;
    grab.current = null;
    if (pull > 90) close();
    setPull(0);
  };

  const days = date ? offset({ date }) : 0;

  return (
    <div className={`sheet-backdrop${shown ? ' shown' : ''}`} onClick={close}>
      <form
        className={`sheet${pull ? ' pulled' : ''}`}
        style={pull ? { transform: `translateY(${pull}px)` } : undefined}
        onClick={(e) => e.stopPropagation()}
        onSubmit={submit}
      >
        <div className="sheet-grab" onPointerDown={down} onPointerMove={move} onPointerUp={up} onPointerCancel={up}>
          <span />
        </div>
        <header className="sheet-bar">
          <button type="button" className="link" onClick={close}>{t.cancel}</button>
          <strong>{isNew ? t.newTitle : t.editTitle}</strong>
          <button type="submit" className="link strong" disabled={!valid}>{t.save}</button>
        </header>

        <div className="preview" style={{ '--tone': event.color }} aria-hidden="true">
          <span className="hero-rings" />
          <span className="preview-title">{title.trim() || t.namePlaceholder}</span>
          <span className="preview-count"><Count days={days} /></span>
        </div>

        <div className="group">
          <label className="field">
            <span>{t.name}</span>
            <input value={title} onChange={(e) => setTitle(e.target.value)} placeholder={t.namePlaceholder} maxLength={30} enterKeyHint="done" />
          </label>
          <label className="field">
            <span>{t.date}</span>
            <input type="date" value={date} onChange={(e) => setDate(e.target.value)} required />
          </label>
        </div>

        {!isNew && (
          <button type="button" className={`remove${sure ? ' sure' : ''}`} onClick={() => (sure ? leave(() => onRemove(event.id)) : setSure(true))}>
            {sure ? t.removeSure : t.remove}
          </button>
        )}
      </form>
    </div>
  );
}
