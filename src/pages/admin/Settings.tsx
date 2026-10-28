import React, { useEffect, useState } from 'react';
import { Layout } from '../../components/Layout';
import { Badge, Button, Card, Chips, Empty, Field, Input, NumInput, Select, Table, Td, Tabs, toast, useAction, useLoad } from '../../components/ui';
import { db } from '../../lib/sb';
import { useApp } from '../../state';
import { BANKS } from '../../lib/vietqr';
import { fmtDate, fmtDateTime, money } from '../../lib/format';

const TG_EVENTS: [string, string][] = [['leave_request', 'Đơn nghỉ / đơn công mới'], ['attendance_flag', 'Chấm công ngoài IP'], ['quote_approval', 'Báo giá chờ duyệt giá'], ['quote_won', 'Chốt đơn'],
  ['support', 'Gọi hỗ trợ'], ['ticket', 'Ticket mới'], ['announcement', 'Bảng tin toàn công ty'], ['payroll', 'Chốt lương'], ['daily_summary', 'Tóm tắt 9h sáng'], ['report_missing', 'Sale chưa nộp báo cáo 18h'], ['test', 'Tin thử']];

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
  if (a.isAdmin || a.has('hcns')) tabs.push(['attendance', 'Chấm công & lịch'], ['holidays', 'Ngày lễ']);
  if (a.isAdmin) tabs.push(['payroll', 'Lương & KPI'], ['crm', 'Tham số CRM'], ['lookups', 'Danh mục'], ['org', 'Phòng ban']);
  const [tab, setTab] = useState(tabs[0]?.[0] || '');
  return (
    <Layout title="Cấu hình hệ thống">
      <Tabs value={tab} onChange={setTab} tabs={tabs} />
      <div className="mt-4 max-w-4xl">
        {tab === 'telegram' && <Telegram />}{tab === 'quote' && <QuoteCfg />}{tab === 'company' && <Company />}{tab === 'attendance' && <AttendanceCfg />}
        {tab === 'holidays' && <Holidays />}{tab === 'payroll' && <PayrollCfg />}{tab === 'crm' && <CrmCfg />}{tab === 'lookups' && <Lookups />}{tab === 'org' && <Org />}
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
      <p className="mt-3 text-xs text-ink-500">Chấm ngoài IP vẫn được ghi nhận nhưng gắn cờ chờ quản lý xác nhận (không chặn), vì IP nhà mạng có thể đổi. Quỹ phút vượt mức: phần vượt không tính lương — không có phạt tiền.</p>
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
      <Card title={`Chỉ tiêu KPI (tổng trọng số ${sumW}%)`}>
        <Table head={['Chỉ số', 'Chỉ tiêu / ngày', 'Trọng số %']}>{Object.entries(metrics).map(([key, m]: any) => <tr key={key}><Td>{m.label}</Td>
          <Td><NumInput value={m.day} onChange={v => k.set('metrics')({ ...metrics, [key]: { ...m, day: v ?? 0 } })} /></Td><Td><NumInput value={m.weight} onChange={v => k.set('metrics')({ ...metrics, [key]: { ...m, weight: v ?? 0 } })} /></Td></tr>)}</Table>
        <div className="mt-3 grid gap-3 sm:grid-cols-3"><Field label="Hệ số chỉ tiêu nhân viên mới"><NumInput value={k.v.new_hire_factor} onChange={k.set('new_hire_factor')} /></Field></div>
        {sumW !== 100 && <p className="mt-2 text-sm text-red-600">Tổng trọng số phải bằng 100%.</p>}
        <Button className="mt-3" variant="primary" disabled={sumW !== 100} loading={k.busy} onClick={k.save}>Lưu KPI</Button>
      </Card>
    </div>
  );
}

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
