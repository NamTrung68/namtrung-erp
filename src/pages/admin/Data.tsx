import React, { useState } from 'react';
import { Layout } from '../../components/Layout';
import { Button, Card, Empty, Field, Input, Loading, Select, Table, Td, Tabs, Textarea, toast, useAction, useLoad, ask } from '../../components/ui';
import { db, storage } from '../../lib/sb';
import { useApp } from '../../state';
import { readXlsx, toISODate } from '../../lib/xlsx';
import { makeZip } from '../../lib/zip';
import { downloadBlob, fmtDate, fmtDateTime, today, monthEnd } from '../../lib/format';

export default function DataAdmin() {
  const a = useApp();
  const tabs: [string, string][] = [['selfie', 'Ảnh chấm công'], ...(a.isAdmin ? [['company', 'KH đang chạy của công ty'], ['audit', 'Nhật ký hệ thống']] as [string, string][] : [['audit', 'Nhật ký']] as [string, string][])];
  const [tab, setTab] = useState(tabs[0][0]);
  return (
    <Layout title="Dữ liệu · Nhật ký">
      <Tabs value={tab} onChange={setTab} tabs={tabs} />
      <div className="mt-4">{tab === 'company' ? <CompanyImport /> : tab === 'selfie' ? <Selfies /> : <Audit />}</div>
    </Layout>
  );
}

function CompanyImport() {
  const [text, setText] = useState(''); const [rows, setRows] = useState<any[]>([]); const { busy, run } = useAction();
  const { data: cur, reload } = useLoad(() => db.from('company_customers').select('batch_id,imported_at', { count: true }).order('imported_at', { asc: false }).limit(1), []);
  const toRow = (r: any[]) => ({ ext_code: r[0], name: r[1], phone: r[2] ? String(r[2]) : null, phone2: r[3] ? String(r[3]) : null, tax_code: r[4] ? String(r[4]) : null, last_order_date: toISODate(r[5]), owner_text: r[6], note: r[7] });
  const fromText = (t: string) => { setText(t); setRows(t.split(/\r?\n/).filter(l => l.trim()).map(l => l.split('\t')).filter(r => !/^m[aã]/i.test(r[0] || '')).map(toRow)); };
  const fromFile = async (f: File) => { const s = (await readXlsx(f))[0]; setRows(s.rows.filter(r => r.length && r[0] && !/^m[aã]/i.test(String(r[0]))).map(toRow)); };
  return (
    <Card title="Danh sách khách đang chạy của công ty (thay toàn bộ mỗi tháng)">
      <p className="mb-3 text-sm text-ink-600">8 cột theo thứ tự: Mã KH · Tên · SĐT · SĐT2/Zalo · MST · Ngày đơn gần nhất · Phụ trách · Ghi chú. Có đơn trong 60 ngày = khóa sale; quá 60 ngày = được đánh thức.
        {(cur as any)?.data?.[0] && <> Lần nhập gần nhất: <b>{fmtDateTime((cur as any).data[0].imported_at)}</b>.</>}</p>
      <input type="file" accept=".xlsx" onChange={e => e.target.files?.[0] && fromFile(e.target.files[0])} className="mb-2 text-sm" />
      <Textarea rows={6} placeholder="Hoặc dán từ Google Sheet (Ctrl+V)…" value={text} onChange={e => fromText(e.target.value)} />
      {rows.length > 0 && <div className="mt-3"><p className="mb-2 text-sm">Đọc được <b>{rows.length}</b> dòng. 5 dòng đầu:</p>
        <Table head={['Mã', 'Tên', 'SĐT', 'SĐT2', 'MST', 'Đơn gần nhất', 'Phụ trách']}>{rows.slice(0, 5).map((r, i) => <tr key={i}><Td>{r.ext_code}</Td><Td>{r.name}</Td><Td>{r.phone}</Td><Td>{r.phone2}</Td><Td>{r.tax_code}</Td><Td>{fmtDate(r.last_order_date)}</Td><Td>{r.owner_text}</Td></tr>)}</Table>
        <Button className="mt-3" variant="primary" loading={busy} onClick={() => run(async () => { const n = await db.rpc('import_company_customers', { p_rows: rows }); setRows([]); setText(''); reload(); toast.ok(`Đã nhập ${n} khách`); })}>Nhập và thay danh sách cũ</Button></div>}
    </Card>
  );
}

function Selfies() {
  const a = useApp(); const [month, setMonth] = useState(today().slice(0, 7)); const [person, setPerson] = useState(''); const { busy, run } = useAction(); const [prog, setProg] = useState('');
  const { data: exp, reload } = useLoad(() => db.rpc('selfies_expired', { p_limit: 1000 }), []);
  const purge = () => run(async () => {
    const list = (exp as any[]) || []; let done = 0;
    for (let i = 0; i < list.length; i += 100) {
      const chunk = list.slice(i, i + 100);
      await storage.remove('selfies', chunk.map(x => x.selfie_path));
      done += await db.rpc('selfies_mark_purged', { p_ids: chunk.map(x => x.id) });
      setProg(`${done}/${list.length}`);
    }
    reload(); return done;
  }, 'Đã xóa ảnh hết hạn');
  const zip = () => run(async () => {
    let qq = db.from('attendance_events').select('id,profile_id,kind,at,selfie_path').gte('work_date', month + '-01').lte('work_date', monthEnd(month + '-01')).is('purged_at', null).order('at').limit(5000);
    if (person) qq = qq.eq('profile_id', person);
    const evs: any[] = (await qq).filter((e: any) => e.selfie_path);
    if (!evs.length) throw new Error('Không có ảnh trong tháng này');
    const files: { name: string; data: Blob }[] = [];
    for (let i = 0; i < evs.length; i++) {
      const e = evs[i]; setProg(`Đang tải ${i + 1}/${evs.length}`);
      try { const b = await storage.download('selfies', e.selfie_path); const t = new Date(e.at).toLocaleString('sv-SE', { timeZone: 'Asia/Ho_Chi_Minh' }).replace(/[: ]/g, '-');
        files.push({ name: `${a.personName(e.profile_id).replace(/[\\/:*?"<>|]/g, '')}/${t}-${e.kind}.jpg`, data: b }); } catch { /* bỏ qua ảnh lỗi */ }
    }
    downloadBlob(`anh-cham-cong-${month}${person ? '-' + a.personName(person) : ''}.zip`, await makeZip(files)); setProg('');
    return files.length;
  }, 'Đã tạo file ZIP');
  return (
    <div className="space-y-4">
      <Card title="Tải ảnh chấm công theo tháng (ZIP)">
        <div className="flex flex-wrap items-end gap-2"><Field label="Tháng"><Input type="month" value={month} onChange={e => setMonth(e.target.value)} /></Field>
          <Field label="Nhân sự"><Select className="w-56" options={a.people.map(p => [p.id, p.full_name])} value={person} onChange={setPerson} placeholder="Tất cả" /></Field>
          <Button variant="dark" loading={busy} onClick={zip}>Tải ZIP</Button><span className="text-sm text-ink-500">{prog}</span></div>
      </Card>
      <Card title={`Ảnh quá hạn lưu (${a.settings.attendance?.selfie_retention_days ?? 60} ngày)`}>
        <p className="mb-3 text-sm">Có <b>{(exp as any[])?.length ?? 0}</b> ảnh đã quá hạn lưu và không bị gắn cờ giữ lại. Nên tải ZIP lưu trữ trước khi xóa nếu cần.</p>
        <Button variant="danger" disabled={!(exp as any[])?.length} loading={busy} onClick={async () => { if (await ask({ title: 'Xóa ảnh hết hạn', message: 'Xóa vĩnh viễn ảnh trên Storage. Dữ liệu giờ chấm công vẫn giữ.', danger: true, ok: 'Xóa' })) purge(); }}>Xóa ảnh hết hạn</Button>
      </Card>
    </div>
  );
}

function Audit() {
  const a = useApp(); const [table, setTable] = useState(''); const [actor, setActor] = useState('');
  const { data, loading } = useLoad(async () => { let q = db.from('audit_logs').select('*').order('at', { asc: false }).limit(300); if (table) q = q.eq('table_name', table); if (actor) q = q.eq('actor_id', actor); return q; }, [table, actor]);
  return (
    <Card title="Nhật ký thay đổi" actions={<><Select className="w-48" options={['customers', 'quotations', 'profiles', 'profile_private', 'leave_requests', 'payslips', 'payslip_adjustments', 'settings', 'exchange_rates', 'documents', 'invites', 'secrets', 'attendance_events', 'job_daily_crm'].map(x => [x, x])} value={table} onChange={setTable} placeholder="Mọi bảng" />
      <Select className="w-48" options={a.people.map(p => [p.id, p.full_name])} value={actor} onChange={setActor} placeholder="Mọi người" /></>} bodyClass="p-0">
      {loading ? <Loading /> : !(data as any[])?.length ? <Empty>Không có dữ liệu (hoặc bạn không có quyền xem)</Empty> :
        <Table head={['Thời gian', 'Người thực hiện', 'Hành động', 'Bảng', 'Bản ghi', 'Thay đổi']}>{(data as any[]).map(l => <tr key={l.id}><Td className="whitespace-nowrap text-xs">{fmtDateTime(l.at)}</Td><Td className="whitespace-nowrap">{a.personName(l.actor_id) || 'Hệ thống'}</Td>
          <Td>{l.action}</Td><Td>{l.table_name}</Td><Td className="max-w-[120px] truncate text-xs">{l.record_id}</Td><Td className="max-w-md text-xs"><code className="line-clamp-3 break-all">{JSON.stringify(l.diff)}</code></Td></tr>)}</Table>}
    </Card>
  );
}
