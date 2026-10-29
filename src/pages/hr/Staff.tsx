import React, { useEffect, useMemo, useState } from 'react';
import { Layout } from '../../components/Layout';
import { Badge, Button, cx, Empty, Field, Input, Loading, Modal, NumInput, Select, StatusChips, Tabs, Textarea, toast, useAction, useLoad, ask } from '../../components/ui';
import { db, storage } from '../../lib/sb';
import { isUrl, prepareUpload } from '../../lib/image';
import { go, useApp, useRoute } from '../../state';
import { addDays, daysBetween, fmtDate, money, today } from '../../lib/format';

const EMP: Record<string, [string, string]> = { thu_viec: ['Thử việc', 'amber'], chinh_thuc: ['Chính thức', 'green'], ctv: ['Cộng tác viên', 'sky'], thoi_vu: ['Thời vụ', 'indigo'], nghi_viec: ['Đã nghỉ việc', 'slate'] };
const CT: Record<string, string> = { thu_viec: 'Thử việc', xac_dinh: 'Xác định thời hạn', khong_xac_dinh: 'Không xác định thời hạn', ctv: 'Cộng tác viên', thoi_vu: 'Thời vụ', phu_luc: 'Phụ lục hợp đồng' };
const CST: Record<string, [string, string]> = { nhap: ['Nháp', 'gray'], hieu_luc: ['Hiệu lực', 'green'], het_han: ['Hết hạn', 'red'], thanh_ly: ['Đã thanh lý', 'slate'] };
const AK: Record<string, string> = { luong_thuong: 'Lương thưởng', hoa_hong: 'Hoa hồng', phu_cap: 'Phụ cấp', cam_ket: 'Cam kết', dao_tao: 'Đào tạo', bao_mat: 'Bảo mật', khac: 'Khác' };
const isHR = (a: ReturnType<typeof useApp>) => a.isAdmin || a.has('hcns', 'bgd');

export default function Staff() {
  const a = useApp(); const { query } = useRoute(); const hr = isHR(a);
  const sel = hr ? query.id || null : a.me.id;
  const [q, setQ] = useState(''); const [f, setF] = useState('');
  const { data: ov, loading, reload } = useLoad(() => hr ? db.rpc<any[]>('hr_overview') : Promise.resolve([]), []);
  const { data: profs } = useLoad(() => hr ? db.from('profiles').select('id,full_name,employee_code,email,phone,org_unit_id,job_level,hire_date,status').order('full_name') : Promise.resolve([]), []);
  const omap = new Map(((ov as any[]) || []).map(o => [o.profile_id, o]));
  const rows = ((profs as any[]) || []).map(p => ({ ...p, o: omap.get(p.id) || {} }));
  const soon = (o: any) => o.contract_end && o.contract_status === 'hieu_luc' && daysBetween(today(), o.contract_end) <= 30;
  const test: Record<string, (r: any) => boolean> = {
    '': r => r.o.employment_status !== 'nghi_viec' && r.status === 'active',
    thu_viec: r => r.o.employment_status === 'thu_viec', chinh_thuc: r => r.o.employment_status === 'chinh_thuc' && r.status === 'active',
    ctv: r => ['ctv', 'thoi_vu'].includes(r.o.employment_status), sap_het: r => soon(r.o), thieu: r => r.o.docs_missing > 0 && r.status === 'active',
    khong_hd: r => !r.o.contract_type && r.status === 'active', nghi: r => r.o.employment_status === 'nghi_viec' || r.status !== 'active',
  };
  const cnt = (k: string) => rows.filter(test[k]).length;
  const list = rows.filter(test[f]).filter(r => !q.trim() || `${r.full_name} ${r.employee_code} ${r.email} ${r.phone}`.toLowerCase().includes(q.trim().toLowerCase()));
  if (!hr) return <Layout title="Hồ sơ của tôi"><div className="mx-auto max-w-4xl"><StaffPanel id={a.me.id} readOnly onChanged={() => {}} /></div></Layout>;
  return (
    <Layout title="Hồ sơ nhân sự">
      <div className={cx(sel && 'hidden xl:block')}>
        <StatusChips value={f} onChange={setF} items={[['', 'Đang làm việc', cnt(''), 'dark'], ['thu_viec', 'Thử việc', cnt('thu_viec'), 'amber'], ['chinh_thuc', 'Chính thức', cnt('chinh_thuc'), 'green'],
          ['ctv', 'CTV · thời vụ', cnt('ctv'), 'sky'], ['sap_het', 'HĐ sắp hết hạn', cnt('sap_het'), 'red'], ['khong_hd', 'Chưa có hợp đồng', cnt('khong_hd'), 'orange'], ['thieu', 'Thiếu giấy tờ', cnt('thieu'), 'pink'], ['nghi', 'Đã nghỉ', cnt('nghi'), 'slate']]} />
        <Input className="mb-3 max-w-md" placeholder="Tìm tên, mã NV, email, SĐT…" value={q} onChange={e => setQ(e.target.value)} />
      </div>
      <div className="flex gap-4">
        <div className={cx('min-w-0 flex-1 rounded-2xl border border-ink-200 bg-white shadow-soft', sel && 'hidden xl:block')}>
          {loading ? <Loading /> : !list.length ? <Empty>Không có nhân sự phù hợp</Empty> :
            <ul className="divide-y divide-ink-100">{list.map(r => { const o = r.o; const unit = a.units.find(u => u.id === r.org_unit_id)?.name;
              return <li key={r.id}><button onClick={() => go(`/hr/staff?id=${r.id}`)} className={cx('grid w-full grid-cols-[1fr_auto] items-center gap-x-3 gap-y-1 px-4 py-3 text-left hover:bg-ink-50 md:grid-cols-[minmax(0,1.4fr)_minmax(0,1fr)_minmax(0,1.2fr)_auto]', sel === r.id && 'bg-brand-50')}>
                <span className="min-w-0"><b className="block truncate">{r.full_name}</b><span className="text-xs text-ink-400">{r.employee_code} · {r.phone || r.email}</span></span>
                <span className="hidden min-w-0 text-xs md:block"><span className="block truncate text-ink-700">{o.position_title || a.levels.find(l => l.code === r.job_level)?.name}</span><span className="text-ink-400">{unit}</span></span>
                <span className="hidden text-xs md:block">{o.contract_type ? <>{CT[o.contract_type]}<span className={cx('block', soon(o) ? 'font-semibold text-red-600' : 'text-ink-400')}>{o.contract_end ? `đến ${fmtDate(o.contract_end)}` : 'không thời hạn'}{soon(o) && ` · còn ${daysBetween(today(), o.contract_end)} ngày`}</span></> : <span className="text-orange-600">Chưa có hợp đồng</span>}</span>
                <span className="flex flex-col items-end gap-1"><Badge color={EMP[o.employment_status]?.[1]}>{EMP[o.employment_status]?.[0] || '—'}</Badge>
                  {o.docs_missing > 0 && <span className="text-[11px] text-pink-700">Thiếu {o.docs_missing} giấy tờ</span>}</span>
              </button></li>; })}</ul>}
        </div>
        {sel && <div className="fixed inset-0 z-30 overflow-y-auto bg-ink-50 p-2 xl:static xl:z-auto xl:w-[56%] xl:max-w-[960px] xl:overflow-visible xl:bg-transparent xl:p-0">
          <StaffPanel key={sel} id={sel} onClose={() => go('/hr/staff')} onChanged={reload} />
        </div>}
      </div>
    </Layout>
  );
}

function StaffPanel({ id, onClose, onChanged, readOnly }: { id: string; onClose?: () => void; onChanged: () => void; readOnly?: boolean }) {
  const a = useApp(); const [tab, setTab] = useState('info');
  const { data: p } = useLoad(() => db.from('profiles').select('*').eq('id', id).maybeSingle(), [id]);
  const can = !readOnly && isHR(a);
  if (!p) return <div className="rounded-2xl border border-ink-200 bg-white"><Loading /></div>;
  const unit = a.units.find(u => u.id === p.org_unit_id)?.name; const lvl = a.levels.find(l => l.code === p.job_level)?.name;
  return (
    <div className="flex flex-col rounded-2xl border border-ink-200 bg-white shadow-soft xl:sticky xl:top-16 xl:max-h-[calc(100vh-5rem)]">
      {onClose && <button onClick={onClose} className="flex items-center gap-1 px-4 pt-3 text-sm font-semibold text-brand-700 xl:hidden">← Quay lại danh sách</button>}
      <div className="flex flex-wrap items-start justify-between gap-2 border-b border-ink-100 px-4 py-3">
        <div className="flex min-w-0 items-center gap-3">
          <div className="grid h-12 w-12 shrink-0 place-items-center rounded-2xl bg-gradient-to-br from-brand-500 to-hot text-lg font-extrabold text-white">{p.full_name.split(' ').slice(-1)[0]?.[0]}</div>
          <div className="min-w-0"><h2 className="truncate text-lg font-bold">{p.full_name}</h2>
            <div className="text-xs text-ink-500">{p.employee_code} · {lvl}{unit && ` · ${unit}`} · {p.email}{p.phone && ` · ${p.phone}`}</div>
            <div className="text-xs text-ink-500">Quản lý: {a.personName(p.manager_id) || '—'} · Vào làm: {fmtDate(p.hire_date) || '—'}</div></div>
        </div>
        <div className="flex gap-1.5">{can && <Button size="sm" onClick={() => go('/admin/users')}>Tài khoản & quyền</Button>}{onClose && <Button size="sm" onClick={onClose}>Đóng</Button>}</div>
      </div>
      <div className="px-4 pt-2"><Tabs value={tab} onChange={setTab} tabs={[['info', 'Thông tin cá nhân'], ['contracts', 'Hợp đồng'], ['agreements', 'Thỏa thuận riêng'], ['docs', 'Giấy tờ']]} /></div>
      <div className="min-h-0 flex-1 overflow-y-auto p-4">
        {tab === 'info' && <InfoTab id={id} can={can} onChanged={onChanged} />}
        {tab === 'contracts' && <Contracts id={id} can={can} onChanged={onChanged} />}
        {tab === 'agreements' && <Agreements id={id} can={can} />}
        {tab === 'docs' && <Docs id={id} can={can} onChanged={onChanged} />}
      </div>
    </div>
  );
}

const REC0 = { gender: '', dob: '', id_number: '', id_issued_on: '', id_issued_by: '', permanent_address: '', current_address: '', personal_email: '', personal_tax_code: '', social_insurance_no: '',
  marital_status: '', dependants: 0, education: '', major: '', school: '', emergency_name: '', emergency_relation: '', emergency_phone: '', position_title: '', employment_status: 'chinh_thuc',
  probation_from: '', probation_to: '', official_date: '', leave_date: '', leave_reason: '', note: '' };
function InfoTab({ id, can, onChanged }: { id: string; can: boolean; onChanged: () => void }) {
  const a = useApp(); const { busy, run } = useAction();
  const { data: r, reload } = useLoad(() => db.from('hr_records').select('*').eq('profile_id', id).maybeSingle(), [id]);
  const [f, setF] = useState<any>(REC0);
  useEffect(() => { setF({ ...REC0, ...Object.fromEntries(Object.entries(r || {}).map(([k, v]) => [k, v ?? ''])) }); }, [r]);
  const ev = (k: string) => (e: any) => setF((x: any) => ({ ...x, [k]: e.target.value }));
  const sv = (k: string) => (v: any) => setF((x: any) => ({ ...x, [k]: v }));
  const save = () => run(async () => {
    const body: any = { ...f, profile_id: id, updated_by: a.me.id }; delete body.updated_at;
    for (const k of Object.keys(body)) if (body[k] === '') body[k] = null;
    if (r) await db.from('hr_records').update(body).eq('profile_id', id); else await db.from('hr_records').insert(body);
    reload(); onChanged();
  }, 'Đã lưu hồ sơ');
  const F = (l: string, k: string, type = 'text', span = false) =>
    <Field key={k} label={l} className={span ? 'sm:col-span-2' : ''}><Input type={type} disabled={!can} value={f[k] || ''} onChange={ev(k)} /></Field>;
  const H = ({ children }: { children: React.ReactNode }) => <h3 className="col-span-full mt-2 border-b border-ink-100 pb-1 text-xs font-bold uppercase tracking-wide text-ink-500">{children}</h3>;
  return (
    <div>
      <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
        <H>Công việc</H>
        {F('Chức danh', 'position_title')}
        <Field label="Tình trạng"><Select disabled={!can} options={Object.entries(EMP).map(([k, v]) => [k, v[0]])} value={f.employment_status} onChange={sv('employment_status')} /></Field>
        {F('Ngày lên chính thức', 'official_date', 'date')}
        {F('Thử việc từ', 'probation_from', 'date')}{F('Thử việc đến', 'probation_to', 'date')}
        {f.employment_status === 'nghi_viec' && <>{F('Ngày nghỉ việc', 'leave_date', 'date')}{F('Lý do nghỉ', 'leave_reason', 'text', true)}</>}
        <H>Cá nhân</H>
        <Field label="Giới tính"><Select disabled={!can} options={[['nam', 'Nam'], ['nu', 'Nữ'], ['khac', 'Khác']]} value={f.gender} onChange={sv('gender')} placeholder="—" /></Field>
        {F('Ngày sinh', 'dob', 'date')}
        <Field label="Hôn nhân"><Select disabled={!can} options={[['doc_than', 'Độc thân'], ['da_ket_hon', 'Đã kết hôn'], ['khac', 'Khác']]} value={f.marital_status} onChange={sv('marital_status')} placeholder="—" /></Field>
        {F('Số CCCD', 'id_number')}{F('Ngày cấp', 'id_issued_on', 'date')}{F('Nơi cấp', 'id_issued_by')}
        {F('Địa chỉ thường trú', 'permanent_address', 'text', true)}{F('Email cá nhân', 'personal_email')}
        {F('Chỗ ở hiện tại', 'current_address', 'text', true)}
        <Field label="Số người phụ thuộc"><NumInput disabled={!can} value={f.dependants} onChange={v => sv('dependants')(v ?? 0)} /></Field>
        {F('Mã số thuế cá nhân', 'personal_tax_code')}{F('Số sổ BHXH', 'social_insurance_no')}<span className="hidden sm:block" />
        <H>Học vấn</H>
        {F('Trình độ', 'education')}{F('Chuyên ngành', 'major')}{F('Trường', 'school')}
        <H>Liên hệ khẩn cấp</H>
        {F('Họ tên', 'emergency_name')}{F('Quan hệ', 'emergency_relation')}{F('Số điện thoại', 'emergency_phone')}
      </div>
      <Field label="Ghi chú nội bộ" className="mt-3"><Textarea disabled={!can} rows={2} value={f.note} onChange={ev('note')} /></Field>
      {can && <div className="sticky bottom-0 mt-3 flex items-center justify-between border-t border-ink-100 bg-white pt-3"><span className="text-xs text-ink-400">{r?.updated_at ? `Cập nhật ${fmtDate(r.updated_at)} bởi ${a.personName(r.updated_by)}` : 'Chưa có hồ sơ'}</span><Button variant="primary" loading={busy} onClick={save}>Lưu hồ sơ</Button></div>}
      {!can && <p className="mt-3 text-xs text-ink-500">Thông tin sai hoặc thay đổi? Báo HCNS để cập nhật.</p>}
    </div>
  );
}

async function openFile(path: string) { try { window.open(await storage.signedUrl('hr', path, 300), '_blank'); } catch (e) { toast.err(e); } }
async function uploadHr(id: string, raw: File) { const file = await prepareUpload(raw); const path = `${id}/${Date.now()}-${file.name.replace(/[^\w.\-]/g, '_')}`; await storage.upload('hr', path, file); return path; }
const LinkBtn = ({ url }: { url?: string | null }) => url ? <a className="inline-flex items-center rounded-lg border border-ink-200 px-2.5 py-1 text-xs font-semibold text-brand-700 hover:bg-ink-50" href={url} target="_blank" rel="noreferrer">🔗 Mở link</a> : null;

function Contracts({ id, can, onChanged }: { id: string; can: boolean; onChanged: () => void }) {
  const { data, loading, reload } = useLoad(() => db.from('hr_contracts').select('*').eq('profile_id', id).order('start_date', { asc: false }), [id]);
  const [edit, setEdit] = useState<any>(null);
  if (loading) return <Loading />;
  const rows = (data as any[]) || [];
  return <div className="space-y-3">
    {can && <div className="flex flex-wrap gap-2"><Button variant="dark" size="sm" onClick={() => setEdit({ contract_type: rows.length ? 'xac_dinh' : 'thu_viec', start_date: today(), status: 'hieu_luc' })}>+ Hợp đồng mới</Button>
      {rows[0] && <Button size="sm" onClick={() => setEdit({ contract_type: 'phu_luc', start_date: today(), status: 'hieu_luc', title: `Phụ lục HĐ ${rows[0].contract_no || ''}`.trim(), base_salary: rows[0].base_salary })}>+ Phụ lục / điều chỉnh lương</Button>}</div>}
    {!rows.length ? <Empty>Chưa có hợp đồng</Empty> : rows.map(c => { const left = c.end_date ? daysBetween(today(), c.end_date) : null;
      return <div key={c.id} className={cx('rounded-2xl border p-3', c.status === 'hieu_luc' ? 'border-emerald-200 bg-emerald-50/40' : 'border-ink-200')}>
        <div className="flex flex-wrap items-center gap-2"><b>{CT[c.contract_type]}</b>{c.contract_no && <span className="text-sm text-ink-500">số {c.contract_no}</span>}<Badge color={CST[c.status][1]}>{CST[c.status][0]}</Badge>
          {c.status === 'hieu_luc' && left !== null && left <= 30 && <Badge color="solidred">Còn {left} ngày</Badge>}
          <span className="ml-auto flex gap-1"><LinkBtn url={c.file_url} />{c.file_path && <Button size="sm" onClick={() => openFile(c.file_path)}>Xem file</Button>}{can && <Button size="sm" onClick={() => setEdit(c)}>Sửa</Button>}</span></div>
        {c.title && <div className="text-sm">{c.title}</div>}
        <div className="mt-1 grid grid-cols-2 gap-x-4 text-sm sm:grid-cols-4">
          <span><span className="text-xs text-ink-400">Hiệu lực</span><br />{fmtDate(c.start_date)} → {c.end_date ? fmtDate(c.end_date) : 'không thời hạn'}</span>
          <span><span className="text-xs text-ink-400">Chức danh</span><br />{c.position_title || '—'}</span>
          <span><span className="text-xs text-ink-400">Lương / đóng BH</span><br /><b>{money(c.base_salary) || '—'}</b>{c.insurance_salary ? ` / ${money(c.insurance_salary)}` : ''}</span>
          <span><span className="text-xs text-ink-400">Phụ cấp</span><br />{money(c.allowance) || '—'}</span></div>
        {c.note && <div className="mt-1 text-xs text-ink-500">{c.note}</div>}
      </div>; })}
    {edit && <ContractModal id={id} c={edit} onClose={() => setEdit(null)} onSaved={() => { setEdit(null); reload(); onChanged(); }} />}
  </div>;
}
function ContractModal({ id, c, onClose, onSaved }: { id: string; c: any; onClose: () => void; onSaved: () => void }) {
  const endFor = (t: string, start: string) => t === 'thu_viec' ? addDays(addDays(start, 60), -1) : t === 'xac_dinh' ? addDays(addDays(start, 365), -1) : '';
  const [f, setF] = useState<any>({ contract_no: '', title: '', position_title: '', end_date: c.id ? '' : endFor(c.contract_type, c.start_date), base_salary: null, insurance_salary: null, allowance: null, signed_on: '', note: '', ...c });
  const [file, setFile] = useState<File | null>(null); const { busy, run } = useAction();
  const s = (k: string) => (v: any) => setF((x: any) => ({ ...x, [k]: v }));
  const setType = (t: string) => setF((x: any) => ({ ...x, contract_type: t, end_date: x.id ? x.end_date : endFor(t, x.start_date) }));
  const save = () => run(async () => {
    if (!f.start_date) throw new Error('Nhập ngày bắt đầu');
    if (f.file_url && !isUrl(f.file_url)) throw new Error('Link không hợp lệ (phải bắt đầu bằng https://)');
    const body: any = { ...f, profile_id: id }; ['created_at', 'updated_at', 'created_by'].forEach(k => delete body[k]);
    for (const k of Object.keys(body)) if (body[k] === '') body[k] = null;
    if (file) body.file_path = await uploadHr(id, file);
    if (f.id) await db.from('hr_contracts').update(body).eq('id', f.id); else await db.from('hr_contracts').insert(body);
    onSaved();
  }, 'Đã lưu hợp đồng');
  const del = async () => { if (await ask({ title: 'Xóa hợp đồng này?', danger: true, ok: 'Xóa' })) run(async () => { await db.from('hr_contracts').delete().eq('id', f.id); onSaved(); }, 'Đã xóa'); };
  return <Modal open onClose={onClose} title={f.id ? 'Sửa hợp đồng' : 'Hợp đồng mới'} footer={<>{f.id && <Button variant="danger" className="mr-auto" onClick={del}>Xóa</Button>}<Button variant="primary" loading={busy} onClick={save}>Lưu</Button></>}>
    <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
      <Field label="Loại hợp đồng" required><Select options={Object.entries(CT)} value={f.contract_type} onChange={setType} /></Field>
      <Field label="Số hợp đồng"><Input value={f.contract_no || ''} onChange={e => s('contract_no')(e.target.value)} placeholder="VD: 12/2026/HĐLĐ-NT" /></Field>
      <Field label="Tiêu đề / nội dung chính" className="sm:col-span-2"><Input value={f.title || ''} onChange={e => s('title')(e.target.value)} /></Field>
      <Field label="Ngày bắt đầu" required><Input type="date" value={f.start_date || ''} onChange={e => s('start_date')(e.target.value)} /></Field>
      <Field label="Ngày kết thúc" hint="Để trống nếu không thời hạn"><Input type="date" value={f.end_date || ''} onChange={e => s('end_date')(e.target.value)} /></Field>
      <Field label="Chức danh"><Input value={f.position_title || ''} onChange={e => s('position_title')(e.target.value)} /></Field>
      <Field label="Ngày ký"><Input type="date" value={f.signed_on || ''} onChange={e => s('signed_on')(e.target.value)} /></Field>
      <Field label="Lương theo hợp đồng"><NumInput value={f.base_salary} onChange={s('base_salary')} /></Field>
      <Field label="Lương đóng bảo hiểm"><NumInput value={f.insurance_salary} onChange={s('insurance_salary')} /></Field>
      <Field label="Phụ cấp"><NumInput value={f.allowance} onChange={s('allowance')} /></Field>
      <Field label="Trạng thái"><Select options={Object.entries(CST).map(([k, v]) => [k, v[0]])} value={f.status} onChange={s('status')} /></Field>
      <Field label="Link hợp đồng trên Google Drive" className="sm:col-span-2" hint="Khuyên dùng: tải bản scan lên Drive rồi dán link — tiết kiệm dung lượng"><Input value={f.file_url || ''} onChange={e => s('file_url')(e.target.value.trim())} placeholder="https://drive.google.com/…" /></Field>
      <Field label="Hoặc tải file (ảnh tự nén ~200 KB, PDF tối đa 5 MB)" className="sm:col-span-2" hint={f.file_path ? 'Đã có file — chọn file mới để thay' : undefined}><input type="file" accept=".pdf,image/*,.doc,.docx" onChange={e => setFile(e.target.files?.[0] || null)} className="text-sm" /></Field>
      <Field label="Ghi chú" className="sm:col-span-2"><Textarea rows={2} value={f.note || ''} onChange={e => s('note')(e.target.value)} /></Field>
    </div>
    <p className="mt-2 text-xs text-ink-500">Hệ thống tự nhắc HCNS trước 30 và 7 ngày khi hợp đồng sắp hết hạn. Lương trong hợp đồng chỉ để lưu hồ sơ; lương tính phiếu lương vẫn lấy ở Nhân sự & phân quyền.</p>
  </Modal>;
}

function Agreements({ id, can }: { id: string; can: boolean }) {
  const a = useApp(); const top = a.isAdmin || a.has('bgd');
  const { data, loading, reload } = useLoad(() => db.from('hr_agreements').select('*').eq('profile_id', id).order('created_at', { asc: false }), [id]);
  const [edit, setEdit] = useState<any>(null); const [file, setFile] = useState<File | null>(null); const { busy, run } = useAction();
  const s = (k: string) => (v: any) => setEdit((x: any) => ({ ...x, [k]: v }));
  const save = () => run(async () => {
    if (!edit.title?.trim()) throw new Error('Nhập tiêu đề thỏa thuận');
    if (edit.file_url && !isUrl(edit.file_url)) throw new Error('Link không hợp lệ (phải bắt đầu bằng https://)');
    const body: any = { ...edit, profile_id: id }; ['created_at', 'updated_at', 'created_by'].forEach(k => delete body[k]);
    for (const k of Object.keys(body)) if (body[k] === '') body[k] = null;
    if (!top) body.confidential = false;
    if (file) body.file_path = await uploadHr(id, file);
    if (edit.id) await db.from('hr_agreements').update(body).eq('id', edit.id); else await db.from('hr_agreements').insert(body);
    setEdit(null); setFile(null); reload();
  }, 'Đã lưu thỏa thuận');
  if (loading) return <Loading />;
  const rows = (data as any[]) || [];
  return <div className="space-y-3">
    <div className="flex flex-wrap items-center justify-between gap-2"><p className="text-xs text-ink-500">Thỏa thuận riêng (hoa hồng riêng, phụ cấp, cam kết…). Mục <b>🔒 Mật</b> chỉ BGĐ/Admin và chính nhân viên xem được.</p>
      {can && <Button variant="dark" size="sm" onClick={() => { setFile(null); setEdit({ kind: 'khac', confidential: top, effective_from: today() }); }}>+ Thỏa thuận</Button>}</div>
    {!rows.length ? <Empty>Chưa có thỏa thuận riêng</Empty> : rows.map(x => { const active = !x.effective_to || x.effective_to >= today();
      return <div key={x.id} className={cx('rounded-2xl border p-3', active ? 'border-brand-200 bg-brand-50/40' : 'border-ink-200 opacity-70')}>
        <div className="flex flex-wrap items-center gap-2"><Badge color="purple">{AK[x.kind]}</Badge><b>{x.title}</b>{x.confidential && <Badge color="red">🔒 Mật</Badge>}{!active && <Badge>Hết hiệu lực</Badge>}
          <span className="ml-auto flex gap-1"><LinkBtn url={x.file_url} />{x.file_path && <Button size="sm" onClick={() => openFile(x.file_path)}>Xem file</Button>}{can && (top || !x.confidential) && <Button size="sm" onClick={() => { setFile(null); setEdit(x); }}>Sửa</Button>}</span></div>
        <div className="mt-1 text-xs text-ink-500">{x.effective_from ? `Từ ${fmtDate(x.effective_from)}` : ''}{x.effective_to ? ` đến ${fmtDate(x.effective_to)}` : x.effective_from ? ' · không thời hạn' : ''}{x.amount ? <> · Giá trị <b className="text-ink-800">{money(x.amount)}</b></> : ''} · lập bởi {a.personName(x.created_by)}</div>
        {x.content && <p className="mt-1 whitespace-pre-wrap text-sm">{x.content}</p>}
      </div>; })}
    {edit && <Modal open onClose={() => setEdit(null)} title={edit.id ? 'Sửa thỏa thuận' : 'Thỏa thuận riêng mới'}
      footer={<>{edit.id && <Button variant="danger" className="mr-auto" onClick={async () => { if (await ask({ title: 'Xóa thỏa thuận này?', danger: true, ok: 'Xóa' })) run(async () => { await db.from('hr_agreements').delete().eq('id', edit.id); setEdit(null); reload(); }, 'Đã xóa'); }}>Xóa</Button>}<Button variant="primary" loading={busy} onClick={save}>Lưu</Button></>}>
      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <Field label="Loại"><Select options={Object.entries(AK)} value={edit.kind} onChange={s('kind')} /></Field>
        <Field label="Giá trị (nếu có)"><NumInput value={edit.amount} onChange={s('amount')} /></Field>
        <Field label="Tiêu đề" required className="sm:col-span-2"><Input value={edit.title || ''} onChange={e => s('title')(e.target.value)} placeholder="VD: Hoa hồng riêng 1% khách VIP chuyển từ công ty cũ" /></Field>
        <Field label="Nội dung thỏa thuận" className="sm:col-span-2"><Textarea rows={4} value={edit.content || ''} onChange={e => s('content')(e.target.value)} /></Field>
        <Field label="Hiệu lực từ"><Input type="date" value={edit.effective_from || ''} onChange={e => s('effective_from')(e.target.value)} /></Field>
        <Field label="Đến (để trống = không thời hạn)"><Input type="date" value={edit.effective_to || ''} onChange={e => s('effective_to')(e.target.value)} /></Field>
        <Field label="Link Google Drive" className="sm:col-span-2"><Input value={edit.file_url || ''} onChange={e => s('file_url')(e.target.value.trim())} placeholder="https://drive.google.com/…" /></Field>
        <Field label="Hoặc tải file (ảnh tự nén ~200 KB)" className="sm:col-span-2"><input type="file" accept=".pdf,image/*,.doc,.docx" onChange={e => setFile(e.target.files?.[0] || null)} className="text-sm" /></Field>
        {top && <label className="flex items-center gap-2 text-sm sm:col-span-2"><input type="checkbox" checked={!!edit.confidential} onChange={e => s('confidential')(e.target.checked)} /> 🔒 Mật — HCNS không xem được, chỉ BGĐ/Admin và nhân viên</label>}
      </div>
    </Modal>}
  </div>;
}

function Docs({ id, can, onChanged }: { id: string; can: boolean; onChanged: () => void }) {
  const a = useApp(); const { busy, run } = useAction();
  const { data, loading, reload } = useLoad(() => db.from('hr_documents').select('*').eq('profile_id', id).order('created_at', { asc: false }), [id]);
  const types = a.opts('hr_doc'); const meta = (code: string) => a.lookups.find(l => l.category === 'hr_doc' && l.code === code)?.extra || {};
  const rows = (data as any[]) || [];
  const up = (type: string, files: FileList | null) => files?.length && run(async () => {
    for (const file of Array.from(files)) { const path = await uploadHr(id, file); await db.from('hr_documents').insert({ profile_id: id, doc_type: type, file_path: path, file_name: path.split('/').pop()!.replace(/^\d+-/, ''), title: a.label('hr_doc', type) }); }
    reload(); onChanged();
  }, 'Đã tải lên');
  const addLink = async (type: string) => {
    const url = await ask({ title: `Thêm link · ${a.label('hr_doc', type)}`, input: { label: 'Link Google Drive', placeholder: 'https://drive.google.com/…', required: true } });
    if (!url) return; if (!isUrl(url)) { toast.err('Link không hợp lệ'); return; }
    run(async () => { await db.from('hr_documents').insert({ profile_id: id, doc_type: type, file_url: url.trim(), file_name: 'Link Drive', title: a.label('hr_doc', type) }); reload(); onChanged(); }, 'Đã thêm link');
  };
  const del = async (d: any) => { if (await ask({ title: `Xóa ${d.file_name}?`, danger: true, ok: 'Xóa' })) run(async () => { if (d.file_path) await storage.remove('hr', [d.file_path]).catch(() => {}); await db.from('hr_documents').delete().eq('id', d.id); reload(); onChanged(); }, 'Đã xóa'); };
  if (loading) return <Loading />;
  const need = types.filter(([k]) => meta(k).required); const have = need.filter(([k]) => rows.some(r => r.doc_type === k)).length;
  return <div className="space-y-3">
    <div className="flex items-center gap-3 rounded-xl bg-ink-50 p-3 text-sm"><b>Hồ sơ bắt buộc: {have}/{need.length}</b>
      <span className="h-2 flex-1 rounded-full bg-ink-200"><span className={cx('block h-2 rounded-full', have === need.length ? 'bg-emerald-500' : 'bg-pink-500')} style={{ width: `${need.length ? have / need.length * 100 : 0}%` }} /></span></div>
    <ul className="divide-y divide-ink-100 rounded-2xl border border-ink-200">{types.map(([k, l]) => { const fs = rows.filter(r => r.doc_type === k);
      return <li key={k} className="px-3 py-2.5">
        <div className="flex flex-wrap items-center gap-2"><span className={cx('grid h-5 w-5 place-items-center rounded-full text-[11px] font-bold', fs.length ? 'bg-emerald-500 text-white' : meta(k).required ? 'bg-pink-100 text-pink-700' : 'bg-ink-100 text-ink-400')}>{fs.length ? '✓' : meta(k).required ? '!' : '·'}</span>
          <b className="text-sm">{l}</b>{meta(k).required && !fs.length && <span className="text-xs text-pink-700">còn thiếu</span>}
          {can && <button className="ml-auto rounded-lg border border-ink-200 px-2 py-1 text-xs font-semibold hover:bg-ink-50" onClick={() => addLink(k)}>🔗 Link</button>}
          {can && <label className="cursor-pointer rounded-lg border border-ink-200 px-2 py-1 text-xs font-semibold hover:bg-ink-50">{busy ? 'Đang tải…' : '+ Tải lên'}<input type="file" multiple className="hidden" onChange={e => { up(k, e.target.files); e.target.value = ''; }} /></label>}</div>
        {fs.length > 0 && <div className="mt-1.5 flex flex-wrap gap-1.5 pl-7">{fs.map(d => <span key={d.id} className="inline-flex items-center gap-1 rounded-lg bg-ink-50 px-2 py-1 text-xs">
          {d.file_url ? <a className="max-w-[220px] truncate font-medium text-brand-700 hover:underline" href={d.file_url} target="_blank" rel="noreferrer">🔗 {d.file_name || 'Link'}</a>
            : <button className="max-w-[220px] truncate font-medium text-brand-700 hover:underline" onClick={() => openFile(d.file_path)}>{d.file_name}</button>}<span className="text-ink-400">{fmtDate(d.created_at)}</span>
          {can && <button className="text-ink-400 hover:text-red-600" onClick={() => del(d)}>✕</button>}</span>)}</div>}
      </li>; })}</ul>
  </div>;
}
