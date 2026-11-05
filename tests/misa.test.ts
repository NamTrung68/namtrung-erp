import { test } from 'node:test';
import assert from 'node:assert/strict';
import { misaTag, payloadDiff, misaOn, batchOf } from '../src/lib/misa';

test('nhãn tình trạng MISA trên phiếu', () => {
  assert.equal(misaTag({ status: 'cho_nhap', misa_at: '2026-11-05', misa: null })?.[0], 'Làm tay · đã xuất Excel');
  assert.equal(misaTag({ status: 'cho_nhap', misa_at: null, misa: null }), null);
  assert.match(misaTag({ status: 'cho_nhap', misa: { st: 'da_tao', lan: 2, cu: true } })![0], /bản cũ/);
  assert.match(misaTag({ status: 'cho_nhap', misa: { st: 'da_tao', lan: 1, khop: false } })![0], /lệch tiền/);
  assert.match(misaTag({ status: 'cho_nhap', misa: { st: 'da_tao', lan: 1, pdf: false } })![0], /chưa có PDF/);
  assert.match(misaTag({ status: 'da_nhap', misa: { st: 'da_tao', lan: 1, pdf: true } })![0], /✓/);
  assert.match(misaTag({ status: 'da_ky', misa: { st: 'da_phat_hanh', so_hd: '00000123' } })![0], /00000123/);
});

test('so nháp trước / dữ liệu mới khi tạo lại', () => {
  const prev = { AccountObjectName: 'A', AccountObjectTaxCode: '0101234567', TotalAmountOC: 1000,
    InvoiceDetails: [{ InventoryItemCode: 'HH1', Quantity: 10, UnitPrice: 90000, VATRate: 8 }, { InventoryItemCode: 'HH2', Quantity: 1, UnitPrice: 5, VATRate: 10 }] };
  const cur = { AccountObjectName: 'A', AccountObjectTaxCode: '0109999999', TotalAmountOC: 1100,
    InvoiceDetails: [{ InventoryItemCode: 'HH1', Quantity: 10, UnitPrice: 92000, VATRate: 8 }, { InventoryItemCode: 'HH3', Quantity: 1, UnitPrice: 5, VATRate: 10 }] };
  const d = payloadDiff(prev, cur);
  assert.ok(d.some(x => x.startsWith('MST: 0101234567 → 0109999999')));
  assert.ok(d.some(x => x.includes('HH1: đơn giá')));
  assert.ok(d.includes('Thêm dòng HH3')); assert.ok(d.includes('Bỏ dòng HH2'));
  assert.ok(d.some(x => x.startsWith('Tổng thanh toán')));
  assert.deepEqual(payloadDiff(prev, prev), []);
});

test('bật API chỉ khi đã chọn mẫu HĐ; lô 1–30', () => {
  assert.equal(misaOn({ accounting: { misa: { enabled: true } } }), false);
  assert.equal(misaOn({ accounting: { misa: { enabled: true, template_id: 't', inv_series: '1C26TYY' } } }), true);
  assert.equal(batchOf({ accounting: { misa: { batch: 99 } } }), 30);
  assert.equal(batchOf({}), 10);
});
