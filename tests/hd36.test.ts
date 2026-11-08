// Bản 36: tình trạng MST Xinvoice → mức cảnh báo
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mstLevel, RateLimit, statusLevel, xinvoiceNorm } from '../src/lib/mst';

test('mức cảnh báo theo tình trạng MST', () => {
  assert.equal(statusLevel('NNT đang hoạt động'), 'green');
  assert.equal(statusLevel('NNT đang hoạt động (đã được cấp GCN ĐKT)'), 'green');
  assert.equal(statusLevel('NNT đang hoạt động (chưa đầy đủ thủ tục cấp MST)'), 'amber');
  for (const s of ['NNT ngừng hoạt động và đã hoàn thành thủ tục chấm dứt hiệu lực MST', 'NNT tạm ngừng KD có thời hạn', 'NNT không hoạt động tại địa chỉ đã đăng ký',
    'NNT ngừng HĐ nhưng chưa hoàn thành thủ tục chấm dứt hiệu lực MST', 'NNT ngừng hoạt động và đã đóng MST']) assert.equal(statusLevel(s), 'red', s);
  for (const s of ['Đợi phản hồi ĐKDN', 'Mã số thuế chờ cập nhật thông tin số định danh cá nhân', 'NNT chờ xác minh tình trạng hoạt động tại địa chỉ đã đăng ký', 'NNT đã chuyển cơ quan thuế quản lý'])
    assert.equal(statusLevel(s), 'amber', s);
});

test('đọc kết quả Xinvoice', () => {
  const r = xinvoiceNorm('0110548462', 200, { orgType: 'Doanh nghiệp', taxID: '0110548462', name: 'CÔNG TY  APOLLO', address: 'HN', taxDepartment: 'Thuế cơ sở 6',
    status: 'NNT ngừng hoạt động và đã hoàn thành thủ tục chấm dứt hiệu lực MST' });
  assert.equal(r.found, true); assert.equal(r.name, 'CÔNG TY APOLLO'); assert.equal(r.active, false); assert.equal(mstLevel(r), 'red'); assert.match(r.warnings[0], /KHÔNG xuất HĐ/);
  const ok = xinvoiceNorm('0108195040', 200, { taxID: '0108195040', name: 'NAM TRUNG', address: 'HN', status: 'NNT đang hoạt động' });
  assert.equal(mstLevel(ok), 'green'); assert.equal(ok.warnings.length, 0);
  const nf = xinvoiceNorm('0101248142', 404, { success: false, message: 'Tax not found - Mã số thuế không tìm thấy' });
  assert.equal(nf.found, false); assert.equal(mstLevel(nf), 'red');
  assert.throws(() => xinvoiceNorm('0108195040', 429, { success: false, error: 'Exceeded free tier limit.' }), (e: any) => e instanceof RateLimit && /đợi/.test(e.message));
});
