// The phone's language: the game's own text follows it.
const language = (() => {
  const tag = (navigator.language || 'en').toLowerCase();
  if (tag.startsWith('zh')) return /hant|tw|hk|mo/.test(tag) ? 'zh-Hant' : 'zh-Hans';
  return ['ja', 'ko', 'es'].find((code) => tag.startsWith(code)) || 'en';
})();

const strings = {
  'zh-Hans': {
    moves: '步数', best: '最佳', hint: '翻开两张，找出一样的水果',
    won: '全部配对！', inMoves: (n) => `用了 ${n} 步`, newBest: '新纪录',
    again: '再来一局', restart: '重新开始', hidden: '还没翻开的牌',
  },
  'zh-Hant': {
    moves: '步數', best: '最佳', hint: '翻開兩張，找出一樣的水果',
    won: '全部配對！', inMoves: (n) => `用了 ${n} 步`, newBest: '新紀錄',
    again: '再來一局', restart: '重新開始', hidden: '還沒翻開的牌',
  },
  en: {
    moves: 'Moves', best: 'Best', hint: 'Flip two cards to find matching fruit',
    won: 'All matched!', inMoves: (n) => `In ${n} moves`, newBest: 'New best',
    again: 'Play Again', restart: 'Start Over', hidden: 'Face-down card',
  },
  ja: {
    moves: '手数', best: 'ベスト', hint: '2 枚めくって、同じフルーツを見つけよう',
    won: '全部そろった！', inMoves: (n) => `${n} 手でクリア`, newBest: '自己ベスト',
    again: 'もう一度', restart: '最初から', hidden: '裏向きのカード',
  },
  ko: {
    moves: '이동', best: '최고', hint: '두 장을 뒤집어 같은 과일을 찾아보세요',
    won: '모두 맞췄어요!', inMoves: (n) => `${n}번 만에 완료`, newBest: '최고 기록',
    again: '한 판 더', restart: '처음부터', hidden: '뒤집힌 카드',
  },
  es: {
    moves: 'Movimientos', best: 'Mejor', hint: 'Da la vuelta a dos cartas para encontrar frutas iguales',
    won: '¡Todo emparejado!', inMoves: (n) => `En ${n} movimientos`, newBest: 'Nuevo récord',
    again: 'Jugar otra vez', restart: 'Empezar de nuevo', hidden: 'Carta boca abajo',
  },
};

export const t = strings[language];
