// The phone's language: the app's own text follows it.
const language = (() => {
  const tag = (navigator.language || 'en').toLowerCase();
  if (tag.startsWith('zh')) return /hant|tw|hk|mo/.test(tag) ? 'zh-Hant' : 'zh-Hans';
  return ['ja', 'ko', 'es'].find((code) => tag.startsWith(code)) || 'en';
})();

const strings = {
  'zh-Hans': {
    future: '还有', past: '已经', today: '就是今天', unit: '天',
    rel: (n, future) => (future ? '天后' : '天前'), todayShort: '今天',
    add: '添加日子', newTitle: '新的日子', editTitle: '编辑日子',
    name: '名称', namePlaceholder: '妈妈生日', date: '日期',
    save: '保存', cancel: '取消', remove: '删除这个日子', removeSure: '再点一次确认删除',
    empty: '还没有日子。添加一个生日、旅行或纪念日。',
    seedNewYear: '新年', seedWeekend: '这个周末', seedThisYear: '今年的第一天',
  },
  'zh-Hant': {
    future: '還有', past: '已經', today: '就是今天', unit: '天',
    rel: (n, future) => (future ? '天後' : '天前'), todayShort: '今天',
    add: '加入日子', newTitle: '新的日子', editTitle: '編輯日子',
    name: '名稱', namePlaceholder: '媽媽生日', date: '日期',
    save: '儲存', cancel: '取消', remove: '刪除這個日子', removeSure: '再點一次確認刪除',
    empty: '還沒有日子。加入一個生日、旅行或紀念日。',
    seedNewYear: '新年', seedWeekend: '這個週末', seedThisYear: '今年的第一天',
  },
  en: {
    future: 'In', past: 'It’s been', today: 'It’s today', unit: 'days', unitOne: 'day',
    rel: (n, future) => `${n === 1 ? 'day' : 'days'} ${future ? 'to go' : 'ago'}`, todayShort: 'Today',
    add: 'Add a Date', newTitle: 'New Date', editTitle: 'Edit Date',
    name: 'Name', namePlaceholder: 'Mom’s birthday', date: 'Date',
    save: 'Save', cancel: 'Cancel', remove: 'Delete This Date', removeSure: 'Tap Again to Delete',
    empty: 'No dates yet. Add a birthday, a trip or an anniversary.',
    seedNewYear: 'New Year', seedWeekend: 'This weekend', seedThisYear: 'First day of the year',
  },
  ja: {
    future: 'あと', past: 'これまで', today: '今日です', unit: '日',
    rel: (n, future) => (future ? '日後' : '日前'), todayShort: '今日',
    add: '日付を追加', newTitle: '新しい日付', editTitle: '日付を編集',
    name: '名前', namePlaceholder: '母の誕生日', date: '日付',
    save: '保存', cancel: 'キャンセル', remove: 'この日付を削除', removeSure: 'もう一度タップで削除',
    empty: 'まだ日付がありません。誕生日や旅行、記念日を追加しましょう。',
    seedNewYear: 'お正月', seedWeekend: '今週末', seedThisYear: '今年の最初の日',
  },
  ko: {
    future: '앞으로', past: '벌써', today: '바로 오늘', unit: '일',
    rel: (n, future) => (future ? '일 후' : '일 전'), todayShort: '오늘',
    add: '날짜 추가', newTitle: '새 날짜', editTitle: '날짜 편집',
    name: '이름', namePlaceholder: '엄마 생신', date: '날짜',
    save: '저장', cancel: '취소', remove: '이 날짜 삭제', removeSure: '한 번 더 탭하면 삭제',
    empty: '아직 날짜가 없어요. 생일, 여행, 기념일을 추가해 보세요.',
    seedNewYear: '새해', seedWeekend: '이번 주말', seedThisYear: '올해의 첫날',
  },
  es: {
    future: 'Faltan', past: 'Han pasado', today: 'Es hoy', unit: 'días', unitOne: 'día',
    rel: (n, future) => `${n === 1 ? 'día' : 'días'}${future ? '' : ' atrás'}`, todayShort: 'Hoy',
    add: 'Añadir fecha', newTitle: 'Nueva fecha', editTitle: 'Editar fecha',
    name: 'Nombre', namePlaceholder: 'Cumpleaños de mamá', date: 'Fecha',
    save: 'Guardar', cancel: 'Cancelar', remove: 'Eliminar esta fecha', removeSure: 'Toca otra vez para eliminar',
    empty: 'Aún no hay fechas. Añade un cumpleaños, un viaje o un aniversario.',
    seedNewYear: 'Año Nuevo', seedWeekend: 'Este fin de semana', seedThisYear: 'Primer día del año',
  },
};

export const t = strings[language];
export const locale = language;

/// "12 days" / "1 day" where the language counts that way.
export function unit(count) {
  return count === 1 && t.unitOne ? t.unitOne : t.unit;
}
