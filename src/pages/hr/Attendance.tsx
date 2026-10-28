import React, { useEffect, useRef, useState } from 'react';
import { Layout } from '../../components/Layout';
import { Badge, Button, Card, Empty, Field, Input, Loading, Modal, NumInput, Select, Table, Td, Tabs, Textarea, toast, useAction, useLoad } from '../../components/ui';
import { db, storage } from '../../lib/sb';
import { useApp } from '../../state';
import { compressImage } from '../../lib/image';
import { fmtDate, fmtTime, monthStart, monthEnd, today } from '../../lib/format';

const REQ: [string, string][] = [['xac_nhan_cong', 'Đơn xác nhận công (quên chấm)'], ['cong_tac', 'Đơn đi công tác / gặp khách'], ['xin_muon_som', 'Xin đi muộn / về sớm']];
const RS: Record<string, [string, string]> = { cho_duyet: ['Chờ duyệt', 'amber'], da_duyet: ['Đã duyệt', 'green'], tu_choi: ['Từ chối', 'red'], huy: ['Đã hủy', 'gray'] };

export default function Attendance() {
  const a = useApp(); const [tab, setTab] = useState('me');
  return (
    <Layout title="Chấm công">
      <Tabs value={tab} onChange={setTab} tabs={[['me', 'Chấm công của tôi'], ['req', 'Đơn công'], ...((a.isLead || a.canHR) ? [['team', 'Bảng chấm công nhân sự']] as [string, string][] : [])]} />
      <div className="mt-4">{tab === 'me' ? <MyAttendance /> : tab === 'req' ? <Requests /> : <TeamAttendance />}</div>
    </Layout>
  );
}

function MyAttendance() {
  const a = useApp(); const cfg = a.settings.attendance || {};
  const [month, setMonth] = useState(today().slice(0, 7));
  const { data: ip } = useLoad(() => db.rpc('my_ip'), []);
  const { data: ev, reload } = useLoad(() => db.from('attendance_events').select('id,kind,at,work_date,ip_ok,status').eq('profile_id', a.me.id).gte('work_date', month + '-01').lte('work_date', monthEnd(month + '-01')).order('at'), [month]);
  const [cam, setCam] = useState<'in' | 'out' | null>(null);
  if (a.me.work_schedule !== 'office') return <Card>Lịch làm việc của bạn ({a.me.work_schedule === 'warehouse' ? 'Kho' : 'không chấm công'}) không cần chấm công bằng ứng dụng.</Card>;
  const days = new Map<string, any[]>(); ((ev as any[]) || []).forEach(e => days.set(e.work_date, [...(days.get(e.work_date) || []), e]));
  const todayEv = days.get(today()) || [];
  const start = cfg.start || '08:00';
  const lateOf = (d: string, list: any[]) => {
    const first = list.find(e => e.kind === 'in'); if (!first) return 0;
    const t = fmtTime(first.at); const [h, m] = t.split(':').map(Number); const [sh, sm] = start.split(':').map(Number);
    return Math.max(0, h * 60 + m - (sh * 60 + sm));
  };
  const totalLate = Array.from(days.entries()).reduce((s, [d, l]) => s + lateOf(d, l), 0);
  return (
    <div className="grid gap-4 lg:grid-cols-[380px_minmax(0,1fr)]">
      <div className="space-y-4">
        {!a.me.selfie_consent && cfg.require_selfie !== false ? <Consent /> :
          <Card title={`Hôm nay ${fmtDate(today())}`}>
            <div className="mb-3 text-sm">Mạng hiện tại: <b>{ip?.ip || '…'}</b> {ip && (ip.ok ? <Badge color="green">Mạng công ty</Badge> : <Badge color="amber">Ngoài mạng công ty — sẽ cần quản lý xác nhận</Badge>)}</div>
            <div className="mb-3 flex gap-2 text-sm"><span>Vào: <b>{fmtTime(todayEv.find(e => e.kind === 'in')?.at) || '—'}</b></span><span>· Ra: <b>{fmtTime([...todayEv].reverse().find(e => e.kind === 'out')?.at) || '—'}</b></span></div>
            <div className="grid grid-cols-2 gap-2">
              <Button variant="primary" className="h-14 text-base" onClick={() => setCam('in')}>Chấm vào</Button>
              <Button variant="dark" className="h-14 text-base" onClick={() => setCam('out')}>Chấm ra</Button>
            </div>
            <p className="mt-3 text-xs text-ink-500">Giờ làm {cfg.start}–{cfg.end}, thứ Bảy đến {cfg.saturday_end}. Quỹ linh hoạt {cfg.flex_minutes} phút/tháng cho đi muộn + về sớm (từ {fmtDate(cfg.flex_start)}). Giờ chấm lấy theo máy chủ.</p>
          </Card>}
        <Card title="Tháng này"><div className="text-sm">Số ngày có chấm công: <b>{days.size}</b><br />Đi muộn (ước tính theo giờ vào): <b>{totalLate}</b> / {cfg.flex_minutes ?? 100} phút
          <div className="mt-2 h-2 rounded-full bg-ink-100"><div className={totalLate > (cfg.flex_minutes ?? 100) ? 'h-2 rounded-full bg-red-500' : 'h-2 rounded-full bg-emerald-500'} style={{ width: `${Math.min(100, totalLate / (cfg.flex_minutes || 100) * 100)}%` }} /></div></div></Card>
      </div>
      <Card title="Lịch sử chấm công" actions={<Input type="month" className="w-40" value={month} onChange={e => setMonth(e.target.value)} />} bodyClass="p-0">
        {!days.size ? <Empty>Chưa có dữ liệu</Empty> : <Table head={['Ngày', 'Vào', 'Ra', 'Muộn', 'Ghi chú']}>{Array.from(days.entries()).reverse().map(([d, l]) => {
          const late = lateOf(d, l); const flagged = l.some(e => e.status === 'flagged');
          return <tr key={d}><Td>{fmtDate(d)}</Td><Td>{fmtTime(l.find(e => e.kind === 'in')?.at)}</Td><Td>{fmtTime([...l].reverse().find(e => e.kind === 'out')?.at)}</Td>
            <Td>{late ? <span className="text-amber-700">{late} phút</span> : ''}</Td><Td>{flagged && <Badge color="amber">Ngoài IP</Badge>}{l.some(e => e.status === 'rejected') && <Badge color="red">Bị từ chối</Badge>}</Td></tr>;
        })}</Table>}
      </Card>
      {cam && <Camera kind={cam} onClose={() => setCam(null)} onDone={() => { setCam(null); reload(); a.refreshMe(); }} />}
    </div>
  );
}

function Consent() {
  const a = useApp(); const { busy, run } = useAction();
  return (
    <Card title="Đồng ý lưu ảnh chấm công">
      <div className="space-y-2 text-sm text-ink-700">
        <p>Công ty dùng ảnh selfie chụp lúc chấm công để xác nhận bạn có mặt. Ảnh được:</p>
        <ul className="list-disc pl-5"><li>nén còn khoảng 100–200 KB, lưu riêng tư;</li><li>chỉ bạn, quản lý trực tiếp và HCNS xem được;</li>
          <li>tự xóa sau {a.settings.attendance?.selfie_retention_days ?? 60} ngày (trừ ảnh đang dùng để giải quyết khiếu nại);</li><li>không dùng nhận diện khuôn mặt tự động.</li></ul>
      </div>
      <Button className="mt-3" variant="primary" loading={busy} onClick={() => run(async () => { await db.rpc('selfie_consent'); await a.refreshMe(); }, 'Đã ghi nhận đồng ý')}>Tôi đồng ý</Button>
    </Card>
  );
}

function Camera({ kind, onClose, onDone }: { kind: 'in' | 'out'; onClose: () => void; onDone: () => void }) {
  const a = useApp(); const video = useRef<HTMLVideoElement>(null); const [shot, setShot] = useState<Blob | null>(null); const [url, setUrl] = useState(''); const [err, setErr] = useState('');
  const [note, setNote] = useState(''); const { busy, run } = useAction(); const stream = useRef<MediaStream | null>(null);
  useEffect(() => {
    navigator.mediaDevices?.getUserMedia({ video: { facingMode: 'user', width: { ideal: 960 } }, audio: false })
      .then(s => { stream.current = s; if (video.current) { video.current.srcObject = s; video.current.play().catch(() => {}); } })
      .catch(() => setErr('Không mở được camera. Cho phép quyền camera cho trang này rồi thử lại, hoặc chọn ảnh từ máy.'));
    return () => stream.current?.getTracks().forEach(t => t.stop());
  }, []);
  const capture = async () => {
    const v = video.current!; const c = document.createElement('canvas'); c.width = v.videoWidth; c.height = v.videoHeight;
    const ctx = c.getContext('2d')!; ctx.translate(c.width, 0); ctx.scale(-1, 1); ctx.drawImage(v, 0, 0);
    ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.fillStyle = 'rgba(0,0,0,.5)'; ctx.fillRect(0, c.height - 34, c.width, 34); ctx.fillStyle = '#fff'; ctx.font = '18px sans-serif';
    ctx.fillText(`${a.me.full_name} · ${new Date().toLocaleString('vi-VN', { timeZone: 'Asia/Ho_Chi_Minh' })}`, 10, c.height - 11);
    const b = await compressImage(c); setShot(b); setUrl(URL.createObjectURL(b));
  };
  const fromFile = async (f: File) => { const b = await compressImage(f); setShot(b); setUrl(URL.createObjectURL(b)); };
  const submit = () => run(async () => {
    if (!shot) throw new Error('Chưa chụp ảnh');
    const path = `${a.me.id}/${today().slice(0, 7)}/${Date.now()}-${kind}.jpg`;
    await storage.upload('selfies', path, shot);
    const r = await db.rpc('attendance_check', { p_kind: kind, p_selfie_path: path, p_note: note || null });
    toast.ok(`Đã chấm ${kind === 'in' ? 'vào' : 'ra'} lúc ${r.at}${r.status === 'flagged' ? ' (ngoài mạng công ty — chờ quản lý xác nhận)' : ''}`);
    onDone();
  });
  return (
    <Modal open onClose={onClose} title={kind === 'in' ? 'Chấm công vào' : 'Chấm công ra'} size="sm"
      footer={<>{shot && <Button onClick={() => { setShot(null); setUrl(''); }}>Chụp lại</Button>}{shot ? <Button variant="primary" loading={busy} onClick={submit}>Xác nhận chấm công</Button> : !err && <Button variant="primary" onClick={capture}>Chụp ảnh</Button>}</>}>
      {err && <div className="mb-3 rounded-lg bg-amber-50 p-3 text-sm text-amber-800">{err}<input className="mt-2 block text-sm" type="file" accept="image/*" capture="user" onChange={e => e.target.files?.[0] && fromFile(e.target.files[0])} /></div>}
      <div className="overflow-hidden rounded-xl bg-ink-900">
        {url ? <img src={url} className="w-full" alt="selfie" /> : <video ref={video} playsInline muted className="w-full -scale-x-100" />}
      </div>
      {shot && <div className="mt-2 text-xs text-ink-500">Ảnh đã nén: {Math.round(shot.size / 1024)} KB</div>}
      <Field label="Ghi chú (nếu có)" className="mt-3"><Input value={note} onChange={e => setNote(e.target.value)} /></Field>
    </Modal>
  );
}

function Requests() {
  const a = useApp(); const [open, setOpen] = useState(false);
  const { data, loading, reload } = useLoad(() => db.from('attendance_requests').select('*').eq('profile_id', a.me.id).order('created_at', { asc: false }).limit(100), []);
  const { run } = useAction();
  return (
    <Card title="Đơn công của tôi" actions={<Button variant="dark" onClick={() => setOpen(true)}>Tạo đơn</Button>} bodyClass="p-0">
      {loading ? <Loading /> : !(data as any[])?.length ? <Empty /> : <Table head={['Loại', 'Ngày', 'Lý do', 'Trạng thái', '']}>{(data as any[]).map(r => (
        <tr key={r.id}><Td>{REQ.find(x => x[0] === r.kind)?.[1]}</Td><Td>{fmtDate(r.work_date)}{r.part !== 'full' && ` (${r.part === 'am' ? 'sáng' : 'chiều'})`}{r.minutes && ` · ${r.minutes} phút`}</Td>
          <Td>{r.reason}{r.decision_note && <div className="text-xs text-ink-400">QL: {r.decision_note}</div>}</Td><Td><Badge color={RS[r.status][1]}>{RS[r.status][0]}</Badge></Td>
          <Td>{r.status === 'cho_duyet' && <Button size="sm" variant="ghost" onClick={() => run(async () => { await db.rpc('cancel_request', { p_table: 'attendance', p_id: r.id }); reload(); }, 'Đã hủy')}>Hủy</Button>}</Td></tr>))}</Table>}
      <NewReq open={open} onClose={() => setOpen(false)} onDone={() => { setOpen(false); reload(); }} />
    </Card>
  );
}
function NewReq({ open, onClose, onDone }: { open: boolean; onClose: () => void; onDone: () => void }) {
  const a = useApp(); const [f, setF] = useState({ kind: 'xac_nhan_cong', work_date: today(), part: 'full', minutes: null as number | null, reason: '' }); const { busy, run } = useAction();
  return (
    <Modal open={open} onClose={onClose} title="Tạo đơn công" size="sm" footer={<Button variant="primary" loading={busy} onClick={() => run(async () => {
      await db.from('attendance_requests').insert({ ...f, profile_id: a.me.id, minutes: f.kind === 'xin_muon_som' ? f.minutes : null }); onDone();
    }, 'Đã gửi đơn — chờ quản lý duyệt')}>Gửi đơn</Button>}>
      <div className="space-y-3">
        <p className="text-xs text-ink-500">Công tác, làm từ xa, đi muộn/về sớm: tạo ở mục <a className="text-brand-700 underline" href="#/hr/leave">Xin nghỉ</a>.</p>
        <Field label="Loại đơn"><Select options={REQ.slice(0, 1)} value={f.kind} onChange={v => setF({ ...f, kind: v })} /></Field>
        <div className="grid grid-cols-2 gap-3"><Field label="Ngày"><Input type="date" value={f.work_date} onChange={e => setF({ ...f, work_date: e.target.value })} /></Field>
          {f.kind === 'xin_muon_som' ? <Field label="Số phút"><NumInput value={f.minutes} onChange={v => setF({ ...f, minutes: v })} /></Field>
            : <Field label="Buổi"><Select options={[['full', 'Cả ngày'], ['am', 'Sáng'], ['pm', 'Chiều']]} value={f.part} onChange={v => setF({ ...f, part: v })} /></Field>}</div>
        <Field label="Lý do / địa điểm" required><Textarea value={f.reason} onChange={e => setF({ ...f, reason: e.target.value })} /></Field>
        <p className="text-xs text-ink-500">{f.kind === 'xac_nhan_cong' ? `Tối đa ${a.settings.attendance?.forgot_limit ?? 3} lần/tháng, gửi trong 24 giờ.` : f.kind === 'xin_muon_som' ? 'Gửi tối thiểu 30 phút trước giờ làm. Thời gian vẫn tính vào quỹ 100 phút.' : 'Sale gặp khách: ghi rõ tên khách, địa điểm.'}</p>
      </div>
    </Modal>
  );
}

function TeamAttendance() {
  const a = useApp(); const [d, setD] = useState(today()); const [img, setImg] = useState<string | null>(null); const { run } = useAction();
  const { data, loading, reload } = useLoad(() => db.from('attendance_events').select('*').eq('work_date', d).order('at'), [d]);
  const by = new Map<string, any[]>(); ((data as any[]) || []).forEach(e => by.set(e.profile_id, [...(by.get(e.profile_id) || []), e]));
  const staff = a.people.filter(p => p.status === 'active');
  const view = (e: any) => run(async () => { if (!e.selfie_path || e.purged_at) throw new Error('Ảnh đã xóa theo thời hạn lưu'); setImg(await storage.signedUrl('selfies', e.selfie_path, 120)); });
  const setStatus = (e: any, status: string) => run(async () => { await db.from('attendance_events').update({ status, reviewed_by: a.me.id }).eq('id', e.id); reload(); }, 'Đã cập nhật');
  return (
    <Card title="Bảng chấm công theo ngày" actions={<Input type="date" className="w-44" value={d} onChange={e => setD(e.target.value)} />} bodyClass="p-0">
      {loading ? <Loading /> : <Table head={['Nhân sự', 'Vào', 'Ra', 'Lượt chấm', '']}>{staff.filter(p => by.has(p.id) || a.isAdmin || a.canHR || p.manager_id === a.me.id).map(p => {
        const l = by.get(p.id) || [];
        return <tr key={p.id}><Td className="whitespace-nowrap">{p.full_name}</Td><Td>{fmtTime(l.find(e => e.kind === 'in')?.at) || <span className="text-ink-300">—</span>}</Td><Td>{fmtTime([...l].reverse().find(e => e.kind === 'out')?.at)}</Td>
          <Td><div className="flex flex-wrap gap-1">{l.map(e => <span key={e.id} className="inline-flex items-center gap-1 rounded-md border border-ink-200 px-1.5 py-0.5 text-xs">
            <button className="text-brand-700" onClick={() => view(e)}>{e.kind === 'in' ? 'Vào' : 'Ra'} {fmtTime(e.at)}</button>
            {e.status === 'flagged' && <><Badge color="amber">IP {e.ip}</Badge><button className="text-emerald-700" onClick={() => setStatus(e, 'valid')}>✓</button><button className="text-red-600" onClick={() => setStatus(e, 'rejected')}>✕</button></>}
            {e.status === 'rejected' && <Badge color="red">Từ chối</Badge>}</span>)}</div></Td><Td /></tr>;
      })}</Table>}
      <Modal open={!!img} onClose={() => setImg(null)} title="Ảnh chấm công" size="sm">{img && <img src={img} className="w-full rounded-lg" alt="" />}</Modal>
    </Card>
  );
}
