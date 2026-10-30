import React, { useEffect, useState } from 'react';
import { Layout } from '../../components/Layout';
import { Badge, Button, Card, Chips, Empty, Field, Input, NumInput, Select, Table, Td, Tabs, toast, useAction, useLoad } from '../../components/ui';
import { db, storage } from '../../lib/sb';
import { CARD_COLORS, LoginCard, LoginContent } from '../../lib/greeting';
import { ROLES } from './Users';
import { prepareUpload } from '../../lib/image';
import { useApp } from '../../state';
import { BANKS } from '../../lib/vietqr';
import { fmtDate, fmtDateTime, money, num } from '../../lib/format';
import { appsScriptCode, saveToDrive } from '../../lib/drive';
import { DEFAULT_ACC_CFG } from '../../lib/doisoat';

const TG_EVENTS: [string, string][] = [['leave_request', 'Đơn nghỉ / đơn công mới'], ['attendance_flag', 'Chấm công ngoài IP'], ['quote_approval', 'Báo giá chờ duyệt giá'], ['quote_won', 'Chốt đơn'],
  ['support', 'Gọi hỗ trợ'], ['ticket', 'Ticket mới'], ['announcement', 'Bảng tin toàn công ty'], ['payroll', 'Chốt lương'], ['daily_summary', 'Tóm tắt 9h sáng'], ['acc_invoice', 'HĐ APT có dòng không đơn / lệch giá'], ['acc_overdue', 'Dòng HĐ quá hạn sale chưa xử lý'], ['report_missing', 'Sale chưa nộp báo cáo 18h'], ['hr', 'Hợp đồng lao động sắp hết hạn'], ['test', 'Tin thử']];

function useSetting(key: string) {
  const a = useApp(); const [v, setV] = useState<any>(a.settings[key] || {}); const { busy, run } = useAction();
  useEffect(() => setV(a.settings[key] || {}), [a.settings[key]]);
  const save = () => run(async () => { await db.rpc('set_setting', { p_key: key, p_value: v }); await a.reload(); }, 'Đã lưu cấu hình');
  return { v, setV, set: (k: string) => (x: any) => setV((o: any) => ({ ...o, [k]: x })), save, busy };
}

export default function Settings() {
  const a = useApp();
  const tabs: [string, string][] = [];
  if (a.isAdmin) tabs.push(['telegram', 'Telegram']);
  if (a.isAdmin || a.has('ke_toan')) tabs.push(['quote', 'Báo giá & tỷ giá'], ['company', 'Công ty & VietQR']);
  if (a.isAdmin || a.has('ke_toan')) tabs.push(['acc', 'Kế toán – Hóa đơn']);
  if (a.isAdmin) tabs.push(['backup', 'Sao lưu Google Drive']);
  if (a.isAdmin || a.has('hcns', 'bgd')) tabs.push(['login', 'Màn hình đăng nhập']);
  if (a.isAdmin || a.has('hcns')) tabs.push(['attendance', 'Chấm công & lịch'], ['holidays', 'Ngày lễ']);
  if (a.isAdmin) tabs.push(['payroll', 'Lương & KPI'], ['crm', 'Tham số CRM'], ['lookups', 'Danh mục'], ['org', 'Phòng ban']);
  const [tab, setTab] = useState(tabs[0]?.[0] || '');
  return (
    <Layout title="Cấu hình hệ thống">
      <Tabs value={tab} onChange={setTab} tabs={tabs} />
      <div className="mt-4 max-w-4xl">
        {tab === 'telegram' && <Telegram />}{tab === 'quote' && <QuoteCfg />}{tab === 'quote' && a.isAdmin && <LibraryCfg />}{tab === 'company' && <Company />}{tab === 'attendance' && <AttendanceCfg />}
        {tab === 'holidays' && <Holidays />}{tab === 'payroll' && <PayrollCfg />}{tab === 'crm' && <CrmCfg />}{tab === 'lookups' && <Lookups />}{tab === 'org' && <Org />}{tab === 'login' && <LoginCfg />}{tab === 'payroll' && <InventoryCfg />}{tab === 'acc' && <AccCfg />}{tab === 'backup' && <DriveCfg />}
      </div>
    </Layout>
  );
}

function Telegram() {
  const s = useSetting('telegram'); const [token, setToken] = useState(''); const { busy, run } = useAction();
  const { data: st, reload } = useLoad(() => db.rpc('secret_status'), []);
  const { data: log, reload: rl } = useLoad(() => db.from('telegram_outbox').select('*').order('id', { asc: false }).limit(15), []);
  const tk = ((st as any[]) || []).find(x => x.key === 'telegram_bot_token');
  return (
    <div className="space-y-4">
      <Card title="Bot Telegram báo cho BGĐ">
        <ol className="mb-4 list-decimal space-y-1 pl-5 text-sm text-ink-600">
          <li>Trong Telegram, nhắn <b>@BotFather</b> → <code>/newbot</code> → đặt tên → nhận <b>token</b> dạng <code>123456:ABC…</code>.</li>
          <li>Tạo nhóm Telegram, thêm bot vào nhóm, gửi 1 tin bất kỳ trong nhóm.</li>
          <li>Lấy <b>chat id</b> của nhóm (số âm, VD <code>-1001234567890</code>): thêm bot <b>@RawDataBot</b> vào nhóm hoặc mở <code>https://api.telegram.org/bot&lt;token&gt;/getUpdates</code>.</li>
          <li>Dán token + chat id dưới đây, bật và bấm <b>Gửi tin thử</b>.</li></ol>
        <div className="grid gap-3 sm:grid-cols-2">
          <Field label="Bot token (lưu mã hóa phía server, không hiển thị lại)" hint={tk?.is_set ? `Đã lưu: ${tk.masked} · ${fmtDateTime(tk.updated_at)}` : 'Chưa có token'}>
            <div className="flex gap-2"><Input type="password" placeholder="123456:ABC-DEF…" value={token} onChange={e => setToken(e.target.value)} />
              <Button loading={busy} onClick={() => run(async () => { await db.rpc('set_secret', { p_key: 'telegram_bot_token', p_value: token.trim() }); setToken(''); reload(); }, 'Đã lưu token')}>Lưu</Button></div></Field>
          <Field label="Chat id nhóm"><Input value={s.v.chat_id || ''} onChange={e => s.set('chat_id')(e.target.value.trim())} placeholder="-100…" /></Field>
        </div>
        <label className="mt-3 flex items-center gap-2 text-sm"><input type="checkbox" checked={!!s.v.enabled} onChange={e => s.set('enabled')(e.target.checked)} /> Bật gửi Telegram</label>
        <Field label="Sự kiện gửi lên nhóm" className="mt-3"><Chips options={TG_EVENTS} value={s.v.events || []} onChange={s.set('events')} /></Field>
        <div className="mt-4 flex gap-2"><Button variant="primary" loading={s.busy} onClick={s.save}>Lưu cấu hình</Button>
          <Button loading={busy} onClick={() => run(async () => { const r = await db.rpc('telegram_test', {}); toast.info(String(r), 'Kết quả'); setTimeout(rl, 1500); })}>Gửi tin thử</Button></div>
      </Card>
      <Card title="Tin đã gửi gần đây" bodyClass="p-0">{!(log as any[])?.length ? <Empty /> : <Table head={['Thời gian', 'Sự kiện', 'Nội dung', 'Lỗi']}>{(log as any[]).map(l => (
        <tr key={l.id}><Td className="whitespace-nowrap text-xs">{fmtDateTime(l.created_at)}</Td><Td>{l.event}</Td><Td className="max-w-md truncate text-xs">{l.message.replace(/<[^>]+>/g, '')}</Td><Td className="text-xs text-red-600">{l.error}</Td></tr>))}</Table>}</Card>
    </div>
  );
}

function QuoteCfg() {
  const s = useSetting('quote_defaults'); const a = useApp(); const { busy, run } = useAction();
  const { data: rates, reload } = useLoad(() => db.from('exchange_rates').select('*').order('effective_from', { asc: false }).limit(30), []);
  const [nr, setNr] = useState({ rate_type: 'ban', rate: null as number | null, note: '' });
  const gv = s.v.giaVonKhoi || {};
  return (
    <div className="space-y-4">
      <Card title="Bảng tỷ giá CNY/VND" actions={null}>
        <div className="mb-3 grid gap-2 sm:grid-cols-[180px_160px_1fr_auto]">
          <Select options={[['ban', 'Tỷ giá bán chuẩn'], ['san', 'Tỷ giá sàn (dưới = cần duyệt)'], ['von', 'Tỷ giá vốn (dưới = cấm)']]} value={nr.rate_type} onChange={v => setNr({ ...nr, rate_type: v })} />
          <NumInput placeholder="Tỷ giá" value={nr.rate} onChange={v => setNr({ ...nr, rate: v })} /><Input placeholder="Ghi chú" value={nr.note} onChange={e => setNr({ ...nr, note: e.target.value })} />
          <Button variant="dark" loading={busy} onClick={() => run(async () => { if (!nr.rate) throw new Error('Nhập tỷ giá'); await db.from('exchange_rates').insert({ rate_type: nr.rate_type, rate: nr.rate, note: nr.note || null }); setNr({ ...nr, rate: null, note: '' }); reload(); }, 'Đã cập nhật tỷ giá')}>Áp dụng ngay</Button>
        </div>
        <Table head={['Loại', 'Tỷ giá', 'Hiệu lực từ', 'Người cập nhật', 'Ghi chú']}>{((rates as any[]) || []).map(r => <tr key={r.id}><Td>{({ ban: 'Bán chuẩn', san: 'Sàn', von: 'Vốn' } as any)[r.rate_type]}</Td><Td className="font-medium">{money(r.rate)}</Td><Td>{fmtDateTime(r.effective_from)}</Td><Td>{a.personName(r.created_by)}</Td><Td>{r.note}</Td></tr>)}</Table>
        <p className="mt-2 text-xs text-ink-500">Báo giá lưu lại tỷ giá tại thời điểm lập, đổi tỷ giá không làm thay đổi báo giá cũ.</p>
      </Card>
      <Card title="Tham số mặc định báo giá">
        <div className="grid gap-3 sm:grid-cols-4">
          {[['phiDVPct', 'Phí dịch vụ mặc định %'], ['phiDVSan', 'Sàn phí DV % (dưới = duyệt)'], ['phiUTPct', 'Phí ủy thác mặc định %'], ['phiUTSan', 'Sàn ủy thác % (dưới = cấm)'], ['vatPct', 'VAT %'],
            ['donGiaKg', 'Đơn giá cước / kg'], ['donGiaKhoi', 'Đơn giá cước / m³'], ['lamTron', 'Làm tròn giá đến'], ['heSoToKhai', 'Hệ số tờ khai APT'], ['tyLeXuatMin', 'Xuất thấp tối thiểu %'], ['tndnPct', 'TNDN xuất cao %'], ['tyLeCoc', '% cọc mặc định'], ['hieuLuc', 'Hiệu lực báo giá (ngày)']].map(([k, l]) =>
            <Field key={k} label={l}><NumInput value={s.v[k]} onChange={s.set(k)} /></Field>)}
          <Field label="Giá vốn cước kho HN / m³"><NumInput value={gv.HN} onChange={x => s.set('giaVonKhoi')({ ...gv, HN: x })} /></Field>
          <Field label="Giá vốn cước kho HCM / m³"><NumInput value={gv.HCM} onChange={x => s.set('giaVonKhoi')({ ...gv, HCM: x })} /></Field>
          <Field label="Phí UT mặc định tính trên"><Select options={[['giaXuat', 'Giá xuất'], ['tienHang', 'Tiền hàng']]} value={s.v.coSoUyThac} onChange={s.set('coSoUyThac')} /></Field>
          <Field label="Thuế NK mặc định tính trên"><Select options={[['toKhai', 'Trị giá khai APT'], ['giaXuat', 'Giá xuất']]} value={s.v.coSoThueNK} onChange={s.set('coSoThueNK')} /></Field>
        </div>
        <Button className="mt-4" variant="primary" loading={s.busy} onClick={s.save}>Lưu</Button>
      </Card>
    </div>
  );
}

function Company() {
  const c = useSetting('company'); const q = useSetting('vietqr');
  return (
    <div className="space-y-4">
      <Card title="Thông tin công ty (in trên báo giá)"><div className="grid gap-3 sm:grid-cols-2">
        {[['name', 'Tên công ty'], ['short', 'Tên ngắn'], ['address', 'Địa chỉ'], ['hotline', 'Hotline'], ['email', 'Email'], ['tax_code', 'MST'], ['website', 'Website']].map(([k, l]) => <Field key={k} label={l}><Input value={c.v[k] || ''} onChange={e => c.set(k)(e.target.value)} /></Field>)}
      </div><Button className="mt-4" variant="primary" loading={c.busy} onClick={c.save}>Lưu</Button></Card>
      <Card title="Tài khoản nhận tiền khách (QR trên báo giá)"><div className="grid gap-3 sm:grid-cols-2">
        <Field label="Ngân hàng"><Select options={BANKS} value={q.v.bank_bin || ''} onChange={q.set('bank_bin')} /></Field>
        <Field label="Tên ngân hàng in trên báo giá"><Input value={q.v.bank_name || ''} onChange={e => q.set('bank_name')(e.target.value)} /></Field>
        <Field label="Số tài khoản"><Input value={q.v.account || ''} onChange={e => q.set('account')(e.target.value)} /></Field>
        <Field label="Chủ tài khoản (không dấu)"><Input value={q.v.holder || ''} onChange={e => q.set('holder')(e.target.value.toUpperCase())} /></Field>
      </div><Button className="mt-4" variant="primary" loading={q.busy} onClick={q.save}>Lưu</Button></Card>
    </div>
  );
}

function AttendanceCfg() {
  const s = useSetting('attendance'); const [ip, setIp] = useState(''); const { data: my } = useLoad(() => db.rpc('my_ip'), []);
  const list: string[] = s.v.ip_whitelist || [];
  return (
    <Card title="Chấm công">
      <div className="grid gap-3 sm:grid-cols-4">
        {[['start', 'Giờ vào'], ['end', 'Giờ ra'], ['saturday_end', 'Thứ Bảy ra lúc'], ['lunch_start', 'Nghỉ trưa từ'], ['lunch_end', 'Nghỉ trưa đến']].map(([k, l]) => <Field key={k} label={l}><Input type="time" value={s.v[k] || ''} onChange={e => s.set(k)(e.target.value)} /></Field>)}
        <Field label="Công thứ Bảy (văn phòng)"><NumInput value={s.v.saturday_value} onChange={s.set('saturday_value')} /></Field>
        <Field label="Quỹ linh hoạt (phút/tháng)"><NumInput value={s.v.flex_minutes} onChange={s.set('flex_minutes')} /></Field>
        <Field label="Áp dụng quỹ từ ngày"><Input type="date" value={s.v.flex_start || ''} onChange={e => s.set('flex_start')(e.target.value)} /></Field>
        <Field label="Quên chấm tối đa / tháng"><NumInput value={s.v.forgot_limit} onChange={s.set('forgot_limit')} /></Field>
        <Field label="Giữ ảnh selfie (ngày)"><NumInput value={s.v.selfie_retention_days} onChange={s.set('selfie_retention_days')} /></Field>
      </div>
      <div className="mt-4 text-sm font-bold">Điểm chuyên cần (bắt đầu {s.v.chuyen_can?.start ?? 100})</div>
      <div className="mt-2 grid gap-3 sm:grid-cols-4">{[['khong_phep', 'Trừ / ngày nghỉ không phép, vắng không đơn'], ['bao_gap', 'Trừ / đơn báo gấp'], ['quen_cham', 'Trừ / lần quên chấm'], ['moi_10_phut_vuot', 'Trừ / 10 phút vượt quỹ']].map(([k, l]) =>
        <Field key={k} label={l}><NumInput value={s.v.chuyen_can?.[k]} onChange={x => s.set('chuyen_can')({ ...(s.v.chuyen_can || {}), [k]: x ?? 0 })} /></Field>)}</div>
      <label className="mt-3 flex items-center gap-2 text-sm"><input type="checkbox" checked={s.v.require_selfie !== false} onChange={e => s.set('require_selfie')(e.target.checked)} /> Bắt buộc ảnh selfie</label>
      <Field label="IP mạng công ty (để trống = không kiểm tra IP)" className="mt-4" hint={`IP của bạn lúc này: ${my?.ip || '?'} — bấm "Thêm IP hiện tại" khi đang ngồi ở văn phòng.`}>
        <div className="flex flex-wrap gap-1.5">{list.map(x => <Badge key={x}>{x} <button className="ml-1 text-red-600" onClick={() => s.set('ip_whitelist')(list.filter(y => y !== x))}>✕</button></Badge>)}</div>
        <div className="mt-2 flex gap-2"><Input className="max-w-xs" placeholder="VD 113.190.1.2 hoặc 113.190.1.0/24" value={ip} onChange={e => setIp(e.target.value)} />
          <Button onClick={() => { if (ip.trim()) { s.set('ip_whitelist')([...list, ip.trim()]); setIp(''); } }}>Thêm</Button>
          {my?.ip && <Button onClick={() => !list.includes(my.ip) && s.set('ip_whitelist')([...list, my.ip])}>Thêm IP hiện tại</Button>}</div>
      </Field>
      <Field label="Khi chấm công ngoài IP công ty" className="mt-4 max-w-md">
        <Select options={[['block', '⛔ Chặn — phải ở mạng văn phòng mới chấm được'], ['flag', '⏳ Cho chấm, chờ quản lý xác nhận (không chặn)']]} value={s.v.outside_ip || 'flag'} onChange={s.set('outside_ip')} /></Field>
      <p className="mt-2 text-xs text-ink-500">{(s.v.outside_ip || 'flag') === 'block' ? 'Nhân viên ngoài mạng công ty sẽ thấy thông báo và không chấm được. Lưu ý: IP nhà mạng có thể đổi — khi đổi mạng, vào đây bấm "Thêm IP hiện tại". Đi công tác / gặp khách tạo đơn ở mục Xin nghỉ.' : 'Chấm ngoài IP vẫn được ghi nhận nhưng gắn cờ, quản lý xác nhận ✓ hoặc từ chối ✕ ở Bảng chấm công nhân sự.'} Chỉ áp dụng khi đã khai báo IP ở trên. Quỹ phút vượt mức: phần vượt không tính lương — không có phạt tiền.</p>
      <Button className="mt-4" variant="primary" loading={s.busy} onClick={s.save}>Lưu</Button>
    </Card>
  );
}

function Holidays() {
  const { data, reload } = useLoad(() => db.from('holidays').select('*').order('day', { asc: false }), []); const [f, setF] = useState({ day: '', name: '', paid: true }); const { busy, run } = useAction();
  return (
    <Card title="Ngày lễ / nghỉ có lương">
      <div className="mb-3 flex flex-wrap gap-2"><Input type="date" className="w-44" value={f.day} onChange={e => setF({ ...f, day: e.target.value })} /><Input className="w-64" placeholder="Tên ngày lễ" value={f.name} onChange={e => setF({ ...f, name: e.target.value })} />
        <label className="flex items-center gap-1 text-sm"><input type="checkbox" checked={f.paid} onChange={e => setF({ ...f, paid: e.target.checked })} /> Có lương</label>
        <Button variant="dark" loading={busy} onClick={() => run(async () => { await db.from('holidays').upsert(f, 'day'); setF({ day: '', name: '', paid: true }); reload(); }, 'Đã lưu')}>Thêm</Button></div>
      <Table head={['Ngày', 'Tên', 'Có lương', '']}>{((data as any[]) || []).map(h => <tr key={h.day}><Td>{fmtDate(h.day)}</Td><Td>{h.name}</Td><Td>{h.paid ? 'Có' : 'Không'}</Td><Td><Button size="sm" variant="ghost" onClick={() => run(async () => { await db.from('holidays').delete().eq('day', h.day); reload(); })}>Xóa</Button></Td></tr>)}</Table>
    </Card>
  );
}

function PayrollCfg() {
  const p = useSetting('payroll'); const k = useSetting('kpi'); const a = useApp(); const { busy, run } = useAction();
  const [levels, setLevels] = useState<any[]>(a.levels);
  const metrics = k.v.metrics || {}; const sumW = Object.values(metrics).reduce((s: number, m: any) => s + Number(m.weight || 0), 0);
  const tiers: [number, number][] = p.v.tiers || [];
  return (
    <div className="space-y-4">
      <Card title="Cấp bậc, lương cơ bản mặc định, hoa hồng">
        <Table head={['Cấp bậc', 'Lương cơ bản', 'Hoa hồng % LN', 'Thưởng quản lý đội %']}>{levels.map((l, i) => <tr key={l.code}><Td>{l.name}</Td>
          {['base_salary', 'commission_pct', 'team_bonus_pct'].map(f => <Td key={f}><NumInput value={l[f]} onChange={v => setLevels(ls => ls.map((x, j) => j === i ? { ...x, [f]: v ?? 0 } : x))} /></Td>)}</tr>)}</Table>
        <Button className="mt-3" variant="primary" loading={busy} onClick={() => run(async () => { for (const l of levels) await db.from('job_levels').update({ base_salary: l.base_salary, commission_pct: l.commission_pct, team_bonus_pct: l.team_bonus_pct }).eq('code', l.code); await a.reload(); }, 'Đã lưu cấp bậc')}>Lưu cấp bậc</Button>
      </Card>
      <Card title="Hoa hồng lũy tiến">
        <div className="grid gap-3 sm:grid-cols-3"><Field label="LN tính thưởng = % LN đơn"><NumInput value={p.v.commission_base_pct} onChange={p.set('commission_base_pct')} /></Field>
          <Field label="Bù trừ đơn lỗ tối đa % hoa hồng/kỳ"><NumInput value={p.v.loss_offset_max_pct} onChange={p.set('loss_offset_max_pct')} /></Field></div>
        <Table className="mt-3" head={['Bậc', 'Từ (đ LN tính thưởng)', 'Cộng thêm điểm %']}>{tiers.map((t, i) => <tr key={i}><Td>Bậc {i + 1}</Td>
          <Td><NumInput value={t[0]} onChange={v => p.set('tiers')(tiers.map((x, j) => j === i ? [v ?? 0, x[1]] : x))} /></Td><Td><NumInput value={t[1]} onChange={v => p.set('tiers')(tiers.map((x, j) => j === i ? [x[0], v ?? 0] : x))} /></Td></tr>)}</Table>
        <Button className="mt-3" variant="primary" loading={p.busy} onClick={p.save}>Lưu</Button>
      </Card>
      <Card title="COM theo bộ phận (Mua hàng · CSKH · TP Kế toán)">
        {(() => { const b = p.v.buyer_com || {}; const c = p.v.cskh_com || {}; const k = p.v.accounting_com || {}; const nm: number[] = b.nego_pct_by_month || [2, 3, 4, 5]; const tg: number[] = b.target_pct_by_month || [2, 2.4, 2.7, 3];
          const tiers: { from: number; coef: number }[] = b.coef_tiers || [{ from: 50, coef: 70 }, { from: 80, coef: 85 }, { from: 95, coef: 100 }, { from: 120, coef: 110 }, { from: 130, coef: 120 }]; const bk = p.v.buyer_kpi || {}; const skp = (x: any) => p.set('buyer_kpi')({ ...bk, ...x });
          const sb = (x: any) => p.set('buyer_com')({ ...b, ...x }); const sc = (x: any) => p.set('cskh_com')({ ...c, ...x }); const sk = (x: any) => p.set('accounting_com')({ ...k, ...x });
          return <div className="space-y-4 text-sm">
            <div><div className="mb-2 flex items-center gap-2 font-semibold"><input type="checkbox" checked={b.enabled !== false} onChange={e => sb({ enabled: e.target.checked })} /> Mua hàng: Phí mua hàng × a% + Hoa hồng đàm phán × b% × Hệ số</div>
              <div className="overflow-x-auto"><table className="w-full min-w-[520px] text-sm"><thead><tr className="text-left text-xs text-ink-500"><th className="py-1 pr-2" />{['Tháng thứ 1', 'Tháng thứ 2', 'Tháng thứ 3', 'Từ tháng thứ 4'].map(x => <th key={x} className="px-1 py-1">{x}</th>)}</tr></thead>
                <tbody>{([['target_pct_by_month', 'Chỉ tiêu đàm phán %', tg], ['nego_pct_by_month', 'b% hoa hồng đàm phán', nm]] as const).map(([key, l, arr]) => <tr key={key}><td className="whitespace-nowrap py-1 pr-2 text-xs font-semibold text-ink-600">{l}</td>
                  {[0, 1, 2, 3].map(i => <td key={i} className="px-1 py-1"><NumInput value={arr[i]} onChange={v => sb({ [key]: [0, 1, 2, 3].map(j => j === i ? v ?? 0 : arr[j] ?? 0) })} /></td>)}</tr>)}</tbody></table></div>
              <div className="mt-2 text-xs font-semibold text-ink-600">Hệ số hoa hồng theo % hoàn thành chỉ tiêu đàm phán (dưới mức thấp nhất = 0%)</div>
              <div className="mt-1 grid grid-cols-2 gap-2 sm:grid-cols-5">{tiers.map((t, i) => <div key={i} className="rounded-xl border border-ink-200 p-2"><div className="text-[11px] text-ink-500">Từ % hoàn thành</div><NumInput value={t.from} onChange={v => sb({ coef_tiers: tiers.map((x, j) => j === i ? { ...x, from: v ?? 0 } : x) })} />
                <div className="mt-1 text-[11px] text-ink-500">Hệ số %</div><NumInput value={t.coef} onChange={v => sb({ coef_tiers: tiers.map((x, j) => j === i ? { ...x, coef: v ?? 0 } : x) })} /></div>)}</div>
              <div className="mt-2 grid gap-3 sm:grid-cols-4"><Field label="a% phí mua hàng"><NumInput value={b.fee_pct ?? 2} onChange={v => sb({ fee_pct: v ?? 0 })} /></Field>
                <label className="flex items-end gap-2 pb-2 text-xs sm:col-span-3"><input type="checkbox" checked={!!b.coef_on_fee} onChange={e => sb({ coef_on_fee: e.target.checked })} /> Nhân hệ số cả phần phí mua hàng (mặc định chỉ nhân phần đàm phán)</label></div>
              <p className="mt-1 text-xs text-ink-500">% đàm phán đạt = Σ Tiền hoa hồng đàm phán ÷ Σ (Tiền hàng trên web + Phí vận chuyển nội địa TQ) (VND) các đơn hoàn thành trong tháng. % hoàn thành = % đạt ÷ chỉ tiêu theo tháng thâm niên (tính từ “Ngày vào làm”, trống = từ tháng 4).
                VD: chỉ tiêu 3%, đạt 2,5% → 83,33% → hệ số 85% → COM = phí mua hàng × 2% + đàm phán × 5% × 85%.</p>
              <div className="mt-3 rounded-xl bg-ink-50 p-3"><div className="mb-2 flex items-center gap-2 font-semibold"><input type="checkbox" checked={!!bk.enabled} onChange={e => skp({ enabled: e.target.checked })} /> Lương Mua hàng theo KPI số đơn <span className="text-xs font-normal text-ink-500">(đang {bk.enabled ? 'áp dụng' : 'tắt'})</span></div>
                <div className="grid gap-3 sm:grid-cols-3"><Field label="Chỉ tiêu đơn / tháng"><NumInput value={bk.orders ?? 900} onChange={v => skp({ orders: v ?? 0 })} /></Field><Field label="% lương theo KPI"><NumInput value={bk.share_pct ?? 30} onChange={v => skp({ share_pct: v ?? 0 })} /></Field></div>
                <Field label="Áp dụng cho" className="mt-2"><Chips options={a.people.filter(x => x.status === 'active').map(x => [x.id, x.full_name])} value={bk.profile_ids || []} onChange={v => skp({ profile_ids: v })} /></Field>
                <p className="mt-1 text-xs text-ink-500">Lương = lương theo công × (100% − {bk.share_pct ?? 30}%) + lương theo công × {bk.share_pct ?? 30}% × số đơn ÷ {num(bk.orders ?? 900)} (tối đa 100%). VD lương 7tr, 800 đơn: 4,9tr + 2,1tr × 800/900.</p></div></div>
            <div><div className="mb-2 flex items-center gap-2 font-semibold"><input type="checkbox" checked={c.enabled !== false} onChange={e => sc({ enabled: e.target.checked })} /> CSKH: Phí dịch vụ × % + Phí đàm phán × %</div>
              <div className="grid gap-3 sm:grid-cols-4"><Field label="% phí dịch vụ"><NumInput value={c.fee_pct ?? 2} onChange={v => sc({ fee_pct: v ?? 0 })} /></Field><Field label="% phí đàm phán"><NumInput value={c.nego_pct ?? 1} onChange={v => sc({ nego_pct: v ?? 0 })} /></Field></div></div>
            <div><div className="mb-2 font-semibold">Trưởng phòng Kế toán: % × % LN đơn hoàn thành cả công ty</div>
              <div className="grid gap-3 sm:grid-cols-4"><Field label="% COM"><NumInput value={k.pct ?? 0.5} onChange={v => sk({ pct: v ?? 0 })} /></Field><Field label="% LN tính thưởng"><NumInput value={k.base_pct ?? 60} onChange={v => sk({ base_pct: v ?? 0 })} /></Field></div>
              <Field label="Người được hưởng" className="mt-2"><Chips options={a.people.filter(x => x.status === 'active').map(x => [x.id, x.full_name])} value={k.profile_ids || []} onChange={v => sk({ profile_ids: v })} /></Field></div>
            <Field label="Link mở đơn trên hệ thống ({so} = số đơn, {ma} = mã đơn)" className="max-w-xl"><Input value={p.v.order_link || 'https://ad.namtrunglog.com/don-hang/{so}'} onChange={e => p.set('order_link')(e.target.value)} /></Field>
          </div>; })()}
        <Button className="mt-3" variant="primary" loading={p.busy} onClick={p.save}>Lưu COM</Button>
      </Card>
      <Card title={`Chỉ tiêu KPI (tổng trọng số ${sumW}%)`}>
        <p className="mb-2 text-xs text-ink-500">Mọi chỉ số KPI cấu hình ở đây. <b>Chỉ tiêu / ngày</b> dùng cho thanh tiến độ trên Bảng điều khiển và Báo cáo ngày; <b>Trọng số</b> tính điểm KPI (để 0 nếu chỉ theo dõi, không tính điểm). Bỏ tick “Hiện” để ẩn khỏi dải KPI.</p>
        <div className="overflow-x-auto"><table className="w-full min-w-[560px] text-sm">
          <thead><tr className="border-b border-ink-200 bg-ink-50 text-left text-xs text-ink-500"><th className="px-3 py-2">Chỉ số</th><th className="px-3 py-2">Chỉ tiêu / ngày</th><th className="px-3 py-2">Trọng số %</th><th className="px-3 py-2 text-center">Hiện</th><th /></tr></thead>
          <tbody className="divide-y divide-ink-100">{Object.entries(metrics).sort(([x], [y]) => KPI_ORDER.indexOf(x) - KPI_ORDER.indexOf(y)).map(([key, m]: any) => <tr key={key}>
            <td className="px-3 py-1.5"><Input value={m.label} onChange={e => k.set('metrics')({ ...metrics, [key]: { ...m, label: e.target.value } })} /><div className="mt-0.5 text-[11px] text-ink-400">{KPI_CATALOG[key]?.hint}</div></td>
            <td className="w-36 px-3 py-1.5"><NumInput value={m.day} onChange={v => k.set('metrics')({ ...metrics, [key]: { ...m, day: v ?? 0 } })} /></td>
            <td className="w-32 px-3 py-1.5"><NumInput value={m.weight} onChange={v => k.set('metrics')({ ...metrics, [key]: { ...m, weight: v ?? 0 } })} /></td>
            <td className="px-3 py-1.5 text-center"><input type="checkbox" checked={m.show ?? key !== 'bao_cao'} onChange={e => k.set('metrics')({ ...metrics, [key]: { ...m, show: e.target.checked } })} /></td>
            <td className="px-1"><button className="text-ink-400 hover:text-red-600" title="Bỏ chỉ số" onClick={() => { const n = { ...metrics }; delete n[key]; k.set('metrics')(n); }}>✕</button></td></tr>)}</tbody>
        </table></div>
        {Object.keys(KPI_CATALOG).some(x => !metrics[x]) && <div className="mt-2 flex flex-wrap items-center gap-1.5 text-xs"><span className="text-ink-500">Thêm chỉ số:</span>
          {Object.entries(KPI_CATALOG).filter(([x]) => !metrics[x]).map(([x, c]) => <button key={x} className="rounded-full border border-dashed border-ink-300 px-2.5 py-1 font-semibold hover:border-brand-500 hover:text-brand-700" onClick={() => k.set('metrics')({ ...metrics, [x]: { label: c.label, day: c.day, weight: 0 } })}>+ {c.label}</button>)}</div>}
        <div className="mt-3 grid gap-3 sm:grid-cols-3"><Field label="Hệ số chỉ tiêu nhân viên mới"><NumInput value={k.v.new_hire_factor} onChange={k.set('new_hire_factor')} /></Field></div>
        {sumW !== 100 && <p className="mt-2 text-sm text-red-600">Tổng trọng số phải bằng 100% (đang {sumW}%).</p>}
        <Button className="mt-3" variant="primary" disabled={sumW !== 100} loading={k.busy} onClick={k.save}>Lưu KPI</Button>
      </Card>
    </div>
  );
}

const KPI_CATALOG: Record<string, { label: string; day: number; hint: string }> = {
  kh_moi: { label: 'KH mới nhập hệ thống', day: 15, hint: 'Khách do sale tạo trong ngày' },
  tiep_can: { label: 'Tiếp cận lần đầu', day: 15, hint: 'Khách có nhật ký mục đích “Tiếp cận lần đầu”' },
  ket_noi: { label: 'Kết nối thành công', day: 6, hint: 'Nhật ký có kết quả kết nối được' },
  cham_cu: { label: 'Chăm sóc khách cũ', day: 10, hint: 'Nhật ký chăm sóc khác tiếp cận lần đầu' },
  bao_gia: { label: 'Báo giá gửi khách', day: 1, hint: 'Báo giá chuyển sang Đã gửi' },
  bai_fb: { label: 'Bài FB chính ngạch', day: 2, hint: 'Link bài FB được quản lý bấm Đạt' },
  cuoc_goi_nhat_ky: { label: 'Cuộc gọi có ghi nhật ký', day: 10, hint: 'Nhật ký kênh Gọi điện' },
  tin_nhan_nhat_ky: { label: 'Tin nhắn có ghi nhật ký', day: 10, hint: 'Nhật ký kênh Zalo / SMS / Facebook' },
  bao_cao: { label: 'Báo cáo ngày đúng hạn', day: 1, hint: 'Nộp báo cáo ngày trước hạn' },
  don_chot: { label: 'Đơn chốt', day: 0.2, hint: 'Báo giá chuyển Đã chốt đơn' },
  khach_nong_am: { label: 'Khách nóng / ấm', day: 2, hint: 'Khách được đánh giá nóng hoặc ấm sau chăm sóc' },
  cuoc_goi_khai: { label: 'Cuộc gọi tự khai', day: 30, hint: 'Số cuộc gọi sale tự khai trong báo cáo ngày' },
  tin_nhan_khai: { label: 'Tin nhắn tự khai', day: 30, hint: 'Số tin nhắn sale tự khai trong báo cáo ngày' },
};
const KPI_ORDER = Object.keys(KPI_CATALOG);

function CrmCfg() {
  const s = useSetting('crm');
  return (
    <Card title="Tham số CRM"><div className="grid gap-3 sm:grid-cols-3">
      {[['company_active_days', 'KH công ty "đang chạy" nếu có đơn trong (ngày)'], ['dormant_days', 'Chuyển Kho khách ngủ sau (ngày không đơn)'], ['quote_valid_days', 'Hiệu lực báo giá (ngày)'], ['quote_expire_grace_days', 'Hết hạn báo giá sau hiệu lực + (ngày)'], ['report_deadline_hour', 'Hạn nộp báo cáo ngày (giờ)'], ['forgotten_days', 'Bỏ quên nếu không liên hệ (ngày)']].map(([k, l]) =>
        <Field key={k} label={l}><NumInput value={s.v[k]} onChange={s.set(k)} /></Field>)}
    </div><Button className="mt-4" variant="primary" loading={s.busy} onClick={s.save}>Lưu</Button></Card>
  );
}

function Lookups() {
  const a = useApp(); const cats = Array.from(new Set(a.lookups.map(l => l.category))); const [cat, setCat] = useState(cats[0]); const [f, setF] = useState({ code: '', label: '' }); const { busy, run } = useAction();
  const { data, reload } = useLoad(() => db.from('lookups').select('*').eq('category', cat).order('sort'), [cat]);
  return (
    <Card title="Danh mục (thay sheet CAU_HINH)" actions={<Select className="w-56" options={cats.map(c => [c, c])} value={cat} onChange={setCat} />}>
      <Table head={['Mã', 'Tên hiển thị', 'Thứ tự', 'Đang dùng']}>{((data as any[]) || []).map(l => <tr key={l.code}><Td className="text-xs">{l.code}</Td>
        <Td><Input defaultValue={l.label} onBlur={e => e.target.value !== l.label && run(async () => { await db.from('lookups').update({ label: e.target.value }).eq('category', cat).eq('code', l.code); a.reload(); }, 'Đã lưu')} /></Td>
        <Td>{l.sort}</Td><Td><input type="checkbox" checked={l.active} onChange={e => run(async () => { await db.from('lookups').update({ active: e.target.checked }).eq('category', cat).eq('code', l.code); reload(); a.reload(); })} /></Td></tr>)}</Table>
      <div className="mt-3 flex gap-2"><Input className="w-40" placeholder="ma_khong_dau" value={f.code} onChange={e => setF({ ...f, code: e.target.value.toLowerCase().replace(/[^a-z0-9_]/g, '_') })} /><Input placeholder="Tên hiển thị" value={f.label} onChange={e => setF({ ...f, label: e.target.value })} />
        <Button variant="dark" loading={busy} onClick={() => run(async () => { await db.from('lookups').insert({ category: cat, code: f.code, label: f.label, sort: ((data as any[]) || []).length + 1 }); setF({ code: '', label: '' }); reload(); a.reload(); }, 'Đã thêm')}>Thêm</Button></div>
      <p className="mt-2 text-xs text-ink-500">Không đổi mã của giai đoạn, kết quả chăm sóc gốc — chỉ đổi tên hiển thị hoặc tắt.</p>
    </Card>
  );
}

function Org() {
  const a = useApp(); const [name, setName] = useState(''); const [parent, setParent] = useState(''); const [kind, setKind] = useState('nhom'); const { busy, run } = useAction();
  return (
    <Card title="Phòng ban / nhóm">
      <Table head={['Tên', 'Loại', 'Thuộc']}>{a.units.map(u => <tr key={u.id}><Td>{u.name}</Td><Td>{u.kind}</Td><Td>{a.units.find(x => x.id === u.parent_id)?.name}</Td></tr>)}</Table>
      <div className="mt-3 flex flex-wrap gap-2"><Input className="w-56" placeholder="Tên" value={name} onChange={e => setName(e.target.value)} />
        <Select className="w-36" options={[['khoi', 'Khối'], ['phong', 'Phòng'], ['nhom', 'Nhóm']]} value={kind} onChange={setKind} />
        <Select className="w-56" options={a.units.map(u => [u.id, u.name])} value={parent} onChange={setParent} placeholder="Thuộc…" />
        <Button variant="dark" loading={busy} onClick={() => run(async () => { await db.from('org_units').insert({ name, kind, parent_id: parent || null }); setName(''); await a.reload(); }, 'Đã thêm')}>Thêm</Button></div>
    </Card>
  );
}

function LoginCfg() {
  const a = useApp(); const { busy, run } = useAction();
  const [v, setV] = useState<LoginContent>(a.settings.login_screen || {});
  const [hl, setHl] = useState((a.settings.login_screen?.headlines || []).join('\n'));
  const [ms, setMs] = useState((a.settings.login_screen?.messages || []).join('\n'));
  const cards: LoginCard[] = v.cards || [];
  const setCard = (i: number, patch: Partial<LoginCard>) => setV(x => ({ ...x, cards: cards.map((c, j) => j === i ? { ...c, ...patch } : c) }));
  const upload = async (raw: File) => { const file = await prepareUpload(raw); const path = `login/${Date.now()}-${file.name.replace(/[^\w.\-]/g, '_')}`; await storage.upload('branding', path, file); return storage.publicUrl('branding', path); };
  const lines = (t: string) => t.split('\n').map(x => x.trim()).filter(Boolean);
  const save = () => run(async () => { await db.rpc('set_login_screen', { p_value: { ...v, headlines: lines(hl), messages: lines(ms) } }); await a.reload(); }, 'Đã lưu màn hình đăng nhập');
  return (
    <div className="space-y-4">
      <Card title="Câu chào lớn" actions={<span className="text-xs text-ink-400">{lines(hl).length} câu</span>}>
        <p className="mb-2 text-xs text-ink-500">Mỗi dòng một câu (nên ngắn, 3–8 chữ). Mỗi ngày, mỗi máy hiện một câu khác nhau.</p>
        <textarea rows={5} className="w-full rounded-xl border border-ink-200 p-3 text-sm focus:border-brand-500 focus:outline-none" value={hl} onChange={e => setHl(e.target.value)} />
      </Card>
      <Card title="Lời chúc · thơ · lời khen" actions={<span className="text-xs text-ink-400">{lines(ms).length} dòng</span>}>
        <p className="mb-2 text-xs text-ink-500">Mỗi dòng một lời chúc. Mỗi người, mỗi ngày thấy một câu khác (cũng hiện ở trang Hôm nay sau khi đăng nhập).</p>
        <textarea rows={12} className="w-full rounded-xl border border-ink-200 p-3 text-sm leading-relaxed focus:border-brand-500 focus:outline-none" value={ms} onChange={e => setMs(e.target.value)} />
      </Card>
      <Card title="Thẻ tích cực (tối đa 4)" actions={cards.length < 4 && <Button size="sm" onClick={() => setV(x => ({ ...x, cards: [...cards, { emoji: '⭐', name: '', color: 'sun' }] }))}>+ Thêm thẻ</Button>}>
        <p className="mb-3 text-xs text-ink-500">Vinh danh nhân viên, khách khen, thành tích đội… Có thể tải ảnh người hoặc sản phẩm thay cho biểu tượng.</p>
        <div className="space-y-3">{cards.map((c, i) => (
          <div key={i} className="grid gap-2 rounded-xl border border-ink-200 p-3 sm:grid-cols-[auto_1fr_1fr_auto]">
            <div className="flex items-center gap-2">
              {c.img ? <img src={c.img} className="h-12 w-12 rounded-full border-2 border-ink-900 object-cover" alt="" /> : <div className="grid h-12 w-12 place-items-center rounded-full border-2 border-ink-900 text-xl" style={{ background: CARD_COLORS[c.color || 'sun'] }}>{c.emoji || '✨'}</div>}
              <div className="space-y-1"><Input className="w-16" value={c.emoji || ''} onChange={e => setCard(i, { emoji: e.target.value })} placeholder="😊" />
                <label className="block cursor-pointer text-[11px] font-semibold text-brand-700">{c.img ? 'Đổi ảnh' : 'Tải ảnh'}<input type="file" accept="image/*" className="hidden" onChange={e => { const f = e.target.files?.[0]; if (f) run(async () => setCard(i, { img: await upload(f) })); }} /></label>
                {c.img && <button className="block text-[11px] text-red-600" onClick={() => setCard(i, { img: undefined })}>Bỏ ảnh</button>}</div></div>
            <div className="space-y-1.5"><Input placeholder="Tên / tiêu đề (VD: Linh KD)" value={c.name} onChange={e => setCard(i, { name: e.target.value })} /><Input placeholder="Dòng phụ (VD: Phòng Kinh doanh)" value={c.sub || ''} onChange={e => setCard(i, { sub: e.target.value })} /></div>
            <div className="space-y-1.5"><div className="flex gap-1.5"><Input placeholder="Nhãn màu (VD: Chốt đơn 1 tỷ)" value={c.tag || ''} onChange={e => setCard(i, { tag: e.target.value })} />
              <Select className="w-28" options={Object.keys(CARD_COLORS).map(k => [k, ({ sun: 'Vàng', mint: 'Xanh lá', aqua: 'Xanh dương', hot: 'Hồng', brand: 'Tím', nt: 'Cam' } as any)[k]])} value={c.color || 'sun'} onChange={x => setCard(i, { color: x })} /></div>
              <Input placeholder="Nhãn phụ (VD: Tuần này)" value={c.tag2 || ''} onChange={e => setCard(i, { tag2: e.target.value })} /></div>
            <button className="self-start text-ink-400 hover:text-red-600" onClick={() => setV(x => ({ ...x, cards: cards.filter((_, j) => j !== i) }))}>✕</button>
          </div>))}</div>
      </Card>
      <Card title="Ảnh lớn (không bắt buộc)">
        <div className="flex flex-wrap items-center gap-3">{v.image && <img src={v.image} alt="" className="h-28 w-24 rounded-2xl border-2 border-ink-900 object-cover" />}
          <label className="cursor-pointer rounded-xl border border-ink-200 px-3 py-2 text-sm font-semibold hover:bg-ink-50">{v.image ? 'Đổi ảnh' : 'Tải ảnh đội nhóm / sự kiện'}<input type="file" accept="image/*" className="hidden" onChange={e => { const f = e.target.files?.[0]; if (f) run(async () => { const u = await upload(f); setV(x => ({ ...x, image: u })); }); }} /></label>
          {v.image && <Button size="sm" variant="ghost" onClick={() => setV(x => ({ ...x, image: null }))}>Bỏ ảnh</Button>}</div>
        <p className="mt-2 text-xs text-ink-500">Ảnh dọc, hiện nghiêng như tấm polaroid bên trái màn hình (máy tính). Dùng ảnh nội bộ công ty, đã được người trong ảnh đồng ý.</p>
      </Card>
      <div className="flex items-center gap-3"><Button variant="primary" loading={busy} onClick={save}>Lưu màn hình đăng nhập</Button><a className="text-sm font-semibold text-brand-700" href="./" target="_blank" rel="noreferrer" onClick={e => { e.preventDefault(); window.open(location.pathname + '?preview=login', '_blank'); }}>Xem thử ↗</a></div>
    </div>
  );
}

function InventoryCfg() {
  const s = useSetting('inventory');
  return <Card title="Cảnh báo trùng hàng tồn kho"><div className="grid gap-3 sm:grid-cols-3">
    <Field label="Ngưỡng giống nhau (0–1)" hint="0,5 = khá giống. Tăng lên để ít cảnh báo hơn, giảm xuống để bắt rộng hơn."><NumInput value={s.v.match_threshold} onChange={s.set('match_threshold')} /></Field>
  </div><Button className="mt-3" variant="primary" loading={s.busy} onClick={s.save}>Lưu</Button></Card>;
}

function LibraryCfg() {
  const s = useSetting('library'); const roles: string[] = s.v.freight_roles || [];
  return <Card title="Kho báo giá tham khảo · quyền xem cước" className="mt-4">
    <p className="mb-2 text-xs text-ink-500">Chọn vai trò được xem cột Cước (đơn giá kg / m³) và lấy cước khi “Tạo báo giá tương tự”. Admin luôn xem được.</p>
    <Chips options={ROLES.filter(r => r[0] !== 'admin')} value={roles} onChange={s.set('freight_roles')} />
    <Button className="mt-3" variant="primary" loading={s.busy} onClick={s.save}>Lưu</Button>
  </Card>;
}

function AccCfg() {
  const a = useApp(); const s = useSetting('accounting'); const v = { ...DEFAULT_ACC_CFG, approver_ids: [], ...s.v };
  const P = ({ k, l }: { k: string; l: string }) => <Field label={l}><NumInput value={v[k] === undefined ? null : Math.round(v[k] * 10000) / 100} onChange={x => s.set(k)((x ?? 0) / 100)} /></Field>;
  const L = ({ k, l, hint }: { k: string; l: string; hint?: string }) => <Field label={l} hint={hint}><Input value={(v[k] || []).join(', ')} onChange={e => s.set(k)(e.target.value.split(/[,\s]+/).filter(Boolean))} /></Field>;
  return <div className="space-y-4">
    <Card title="Quy tắc tự chấm dòng hàng (bước B1)">
      <div className="grid gap-3 sm:grid-cols-3"><P k="bien_nt_min" l="Biên NT tối thiểu %" /><P k="bien_muc_tieu" l="Biên NT mục tiêu %" /><P k="bien_nt_max" l="Biên NT tối đa %" /></div>
      <p className="mt-1 text-xs text-ink-500">Biên NT = giá khách ÷ giá HĐ APT − 1. Dưới tối thiểu → chặn, sale giải trình/xin duyệt. Trên tối đa → tự đề xuất APT xuất giá = giá khách ÷ (1 + mục tiêu).</p>
      <div className="mt-3 grid gap-3 sm:grid-cols-3"><Field label="Bỏ qua khi tiền chênh dưới (đ)"><NumInput value={v.tien_bo_qua} onChange={s.set('tien_bo_qua')} /></Field>
        <Field label="Hạn sale xử lý (giờ)"><NumInput value={v.han_sale_gio} onChange={s.set('han_sale_gio')} /></Field>
        <Field label="HĐ APT về muộn sau (ngày)" hint="Tính từ ngày xe"><NumInput value={v.han_hd_ngay ?? 15} onChange={s.set('han_hd_ngay')} /></Field></div>
      <p className="mt-1 text-xs text-ink-500">Đơn APT xuất thẳng khai báo riêng từng xe khi nạp file (mỗi xe một khác).</p>
      <div className="mt-3 grid gap-3 sm:grid-cols-2"><L k="sale_lanchi" l="Tài khoản khách Lanchi" />
        <L k="hs_hop_quy_chuong" l="Chương HS hàng chờ hợp quy" hint="2 số đầu mã HS, VD 61, 62" /></div>
      <Button className="mt-3" variant="primary" loading={s.busy} onClick={s.save}>Lưu</Button>
    </Card>
    <Card title="Người được duyệt mở chặn">
      <p className="mb-2 text-xs text-ink-500">Duyệt dòng chưa có đơn, giá khách = 0, biên NT dưới khung. {a.isAdmin ? 'Chọn người rồi bấm Lưu.' : 'Chỉ Admin/BGĐ được thay đổi danh sách này.'}</p>
      <Chips disabled={!a.isAdmin} options={a.people.filter(x => x.status === 'active').map(x => [x.id, x.full_name])} value={v.approver_ids || []} onChange={s.set('approver_ids')} />
      {a.isAdmin && <Button className="mt-3" variant="primary" loading={s.busy} onClick={s.save}>Lưu</Button>}
    </Card>
  </div>;
}

function DriveCfg() {
  const a = useApp(); const d = a.settings.drive || {}; const { busy, run } = useAction();
  const [keys, setKeys] = useState<{ backup: string; upload: string } | null>(null); const [url, setUrl] = useState(d.url || '');
  const rnd = (n: number) => Array.from(crypto.getRandomValues(new Uint8Array(n)), b => 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'[b % 57]).join('');
  const c = window.NT_CONFIG!; const code = appsScriptCode(c.supabaseUrl, c.supabaseAnonKey);
  const copy = (t: string) => navigator.clipboard.writeText(t).then(() => toast.ok('Đã sao chép'));
  const gen = () => run(async () => { const k = { backup: rnd(48), upload: rnd(32) }; await db.rpc('backup_set_token', { p_token: k.backup }); await db.rpc('set_drive', { p_value: { upload_key: k.upload } }); setKeys(k); await a.reload(); }, 'Đã tạo mã mới');
  const Step = ({ n, children }: { n: number; children: React.ReactNode }) => <li className="flex gap-3"><span className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-brand-600 text-xs font-bold text-white">{n}</span><div className="min-w-0 flex-1 text-sm">{children}</div></li>;
  return <div className="space-y-4">
    <Card title="Trạng thái">
      <div className="text-sm">Sao lưu gần nhất lên Drive: <b>{d.last_backup_at ? fmtDateTime(d.last_backup_at) : 'chưa có'}</b>{d.last_backup_at && (Date.now() - new Date(d.last_backup_at).getTime() > 36 * 36e5) && <Badge color="red" className="ml-2">quá 36 giờ — kiểm tra Apps Script</Badge>}</div>
      <div className="mt-1 text-sm">Lưu file lên Drive: {d.url && d.upload_key ? <Badge color="green">Đã bật</Badge> : <Badge>Chưa bật</Badge>}</div>
      <p className="mt-2 text-xs text-ink-500">Mỗi đêm 1h, Google Drive của anh tự kéo toàn bộ dữ liệu ERP về thư mục <b>NT-ERP/Sao luu</b> (file .json.gz, giữ 60 ngày). File Excel đối soát, XML hóa đơn lưu vào <b>NT-ERP/Ke toan</b>. Không cần nâng gói Supabase. Khôi phục: Dữ liệu · Nhật ký → Khôi phục từ file sao lưu.</p>
    </Card>
    <Card title="Cài đặt 1 lần (khoảng 5 phút, đăng nhập Google của công ty)">
      <ol className="space-y-3">
        <Step n={1}><Button size="sm" variant="dark" loading={busy} onClick={gen}>Tạo mã bí mật mới</Button> <span className="text-xs text-ink-500">(tạo lại sẽ vô hiệu mã cũ)</span>
          {keys && <div className="mt-2 space-y-1 rounded-xl bg-amber-50 p-3 text-xs"><div className="font-semibold text-amber-900">Chỉ hiện 1 lần — dán ngay vào Apps Script (bước 3):</div>
            {[['BACKUP_TOKEN', keys.backup], ['UPLOAD_KEY', keys.upload]].map(([k, v]) => <div key={k} className="flex items-center gap-2"><code className="w-28 font-bold">{k}</code><code className="min-w-0 flex-1 truncate rounded bg-white px-2 py-1">{v}</code><Button size="sm" onClick={() => copy(v)}>Chép</Button></div>)}</div>}</Step>
        <Step n={2}>Mở <a className="font-semibold text-brand-700 underline" href="https://script.google.com/home/projects/create" target="_blank" rel="noreferrer">script.google.com → Dự án mới</a>, xóa hết, dán mã dưới đây, bấm Lưu. <Button size="sm" onClick={() => copy(code)}>Chép mã Apps Script</Button>
          <pre className="mt-2 max-h-40 overflow-auto rounded-xl bg-ink-900 p-3 text-[11px] text-ink-100">{code}</pre></Step>
        <Step n={3}>Bánh răng <b>Project Settings</b> → <b>Script properties</b> → thêm 2 dòng <code>BACKUP_TOKEN</code> và <code>UPLOAD_KEY</code> với giá trị ở bước 1.</Step>
        <Step n={4}>Quay lại Editor, chọn hàm <b>setup</b> → <b>Run</b> → cho phép quyền. Kiểm tra Drive có thư mục <b>NT-ERP/Sao luu</b> với 1 file mới.</Step>
        <Step n={5}><b>Deploy → New deployment → Web app</b>: Execute as <b>Me</b>, Who has access <b>Anyone</b> → Deploy → chép link Web app dán vào đây:
          <div className="mt-2 flex gap-2"><Input placeholder="https://script.google.com/macros/s/…/exec" value={url} onChange={e => setUrl(e.target.value)} />
            <Button variant="primary" loading={busy} onClick={() => run(async () => { await db.rpc('set_drive', { p_value: { url: url.trim() } }); await a.reload(); }, 'Đã lưu link')}>Lưu</Button></div></Step>
        <Step n={6}><Button size="sm" loading={busy} onClick={() => run(async () => { const u = await saveToDrive(a.settings.drive, new Blob(['NT-ERP thử lưu Drive ' + new Date().toLocaleString('vi-VN')], { type: 'text/plain' }), 'thu-luu-drive.txt', 'Thu nghiem'); window.open(u, '_blank'); }, 'Lưu thử thành công')}>Thử lưu 1 file lên Drive</Button></Step>
      </ol>
    </Card>
  </div>;
}
