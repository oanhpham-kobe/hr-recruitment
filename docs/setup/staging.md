# Dựng môi trường staging

Hướng dẫn cho Owner. Mục tiêu: chạy trọn luồng tuyển dụng trên staging để UAT, chi phí 0 đồng.
Chưa bước nào trong tài liệu này được chạy thật; chỗ nào chưa chắc tôi ghi rõ **(chưa kiểm chứng)**.

Không dán bất kỳ secret nào vào chat, issue hay commit. Secret chỉ nằm ở: terminal của bạn,
Cloudflare secrets, Vercel environment variables.

## Tổng quan

| Dịch vụ | Vai trò | Gói |
|---|---|---|
| Supabase `eiu-recruitment-dev` | Database, đăng nhập, phân quyền | Free |
| Vercel | Chạy web app; gửi email; dọn bản ghi cũ | Hobby |
| Cloudflare Worker | Cổng truyền file tới Drive; cron mỗi phút | Free (đo CPU ở bước 6) |
| Google Drive | Lưu file ứng viên; quét mã độc | Workspace EIU |
| Gmail | Gửi thư mời phỏng vấn, thông báo HR, mã OTP | Workspace EIU |

## Bạn cần quyết định trước

1. Email của **Root Admin** đầu tiên (`@eiu.edu.vn`).
2. Tài khoản Google **sở hữu thư mục chứa file** (nên là tài khoản dùng chung của phòng).
3. **Hộp thư gửi** thư mời và OTP (ví dụ một hộp thư tuyển dụng của phòng).
4. Địa chỉ nhận thư thử (`test_sink`): trên staging mọi thư đều chỉ gửi về đây.
5. Danh sách email HR nhận thông báo có phiếu mới.

## 1. Google Cloud

Làm bằng tài khoản `@eiu.edu.vn`. Nếu project hiện tại tạo bằng Gmail cá nhân, hãy tạo project
mới bằng tài khoản EIU: chỉ project thuộc tổ chức EIU mới chọn được loại **Internal** ở bước 1.3,
nếu không token hết hạn sau 7 ngày.

1. Console → chọn project → kiểm tra dòng **Organization** là `eiu.edu.vn`.
2. **APIs & Services → Library**: bật **Google Drive API** và **Gmail API**.
3. **Google Auth Platform → Audience**: User type = **Internal**.
4. **Google Auth Platform → Data Access**: thêm hai scope
   `https://www.googleapis.com/auth/drive.file` và `https://www.googleapis.com/auth/gmail.send`.
5. **Google Auth Platform → Clients → Create client**, tạo hai client:
   - **Desktop app** — dùng cho Drive và Gmail. Ghi lại Client ID và Client secret.
   - **Web application** — dùng cho đăng nhập Google của nhân sự. Authorized redirect URI:
     `https://<project-ref>.supabase.co/auth/v1/callback`.
6. Lấy refresh token, chạy trong thư mục repo (PowerShell):

   ```powershell
   $env:GOOGLE_CLIENT_ID = "<Client ID của Desktop app>"
   $env:GOOGLE_CLIENT_SECRET = "<Client secret của Desktop app>"
   node scripts/google-oauth-token.mjs drive   # đăng nhập bằng tài khoản sở hữu file
   node scripts/google-oauth-token.mjs gmail   # đăng nhập bằng hộp thư gửi
   ```

   Lệnh đầu in `GOOGLE_REFRESH_TOKEN` và `GOOGLE_PRIVATE_FOLDER_ID` (script tự tạo thư mục
   "EIU Recruitment documents (private)" trong Drive của tài khoản đó). Lệnh sau in
   `GMAIL_REFRESH_TOKEN`. **(chưa kiểm chứng với Google thật)**

## 2. Supabase

1. Đăng nhập CLI: `npx supabase@2.116.0 login`, rồi
   `npx supabase@2.116.0 link --project-ref <project-ref>`.
2. Áp migration còn thiếu: `npx supabase@2.116.0 db push`. Xem danh sách nó định áp trước khi
   đồng ý. Không sửa hay gộp file trong `supabase/migrations/`.
3. Dashboard → **Project Settings → API**: ghi lại Project URL, publishable (anon) key,
   service role key và **JWT secret**.
4. Tạo token cho worker (mỗi lệnh in một token, hạn 365 ngày):

   ```powershell
   $env:SUPABASE_JWT_SECRET = "<JWT secret>"
   node scripts/mint-worker-token.mjs drive_storage_worker
   node scripts/mint-worker-token.mjs document_scan_worker
   node scripts/mint-worker-token.mjs storage_cleanup_worker
   node scripts/mint-worker-token.mjs email_worker
   $env:SUPABASE_JWT_SECRET = $null
   ```

   **(chưa kiểm chứng trên Supabase hosted; đã chạy đúng với Supabase local)**
5. **Authentication → Providers → Google**: bật, dán Client ID/secret của client *Web application*.
6. **Authentication → URL Configuration**: Site URL = địa chỉ staging trên Vercel.
7. **Authentication → Emails → SMTP Settings**: bật Custom SMTP để gửi OTP cho ứng viên (email
   mặc định của Supabase chỉ gửi được vài thư mỗi giờ). Host `smtp.gmail.com`, port `465`,
   username = hộp thư gửi, password = **App password** của hộp thư đó (cần bật xác minh 2 bước).
   Mẫu thư OTP nằm ở `supabase/templates/magic_link.html`.
8. Cấu hình gửi thư nghiệp vụ, chạy trong **SQL Editor**:

   ```sql
   update private.email_configuration
   set delivery_paused = false,
       test_sink = '<địa chỉ nhận thư thử>',
       hr_recipients = array['<email HR 1>', '<email HR 2>'];
   ```

   `environment_code` giữ nguyên `TEST`: mọi thư chỉ tới `test_sink`.
9. Root Admin đầu tiên: tôi sẽ viết lệnh SQL tạo dòng người dùng cho email bạn chọn; tài khoản
   được gắn khi người đó đăng nhập Google lần đầu.

## 3. Sinh hai secret dùng chung

```powershell
node -e "console.log(require('crypto').randomBytes(32).toString('base64url'))"  # DRIVE_GRANT_SECRET
node -e "console.log(require('crypto').randomBytes(32).toString('base64url'))"  # CRON_SECRET
```

## 4. Cloudflare Worker

```powershell
cd workers/drive-gateway
npm ci
npx wrangler login
npx wrangler deploy          # in ra địa chỉ https://eiu-private-drive-gateway.<tài khoản>.workers.dev
npx wrangler secret bulk     # dán JSON các giá trị bên dưới
```

| Tên | Giá trị |
|---|---|
| `APP_ORIGIN` | Địa chỉ staging trên Vercel, không có `/` cuối |
| `GATEWAY_ORIGIN` | Địa chỉ `workers.dev` vừa in ra |
| `SUPABASE_URL` | Project URL |
| `SUPABASE_API_KEY` | Publishable (anon) key |
| `DRIVE_GRANT_SECRET` | Bước 3 |
| `CRON_SECRET` | Bước 3 |
| `DRIVE_WORKER_TOKEN` | Token `drive_storage_worker` |
| `SCAN_WORKER_TOKEN` | Token `document_scan_worker` |
| `CLEANUP_WORKER_TOKEN` | Token `storage_cleanup_worker` |
| `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` | Client *Desktop app* |
| `GOOGLE_REFRESH_TOKEN`, `GOOGLE_PRIVATE_FOLDER_ID` | Bước 1.6 (lệnh `drive`) |
| `DRIVE_ENABLED` | `true` |
| `DRIVE_SCHEDULES_VERIFIED` | `false` cho tới khi xong bước 6 |

## 5. Vercel

Trước khi link repo: đặt **Production Branch** khác `main` (ví dụ `staging`) để push lên `main`
không tự deploy. Biến môi trường (tên đầy đủ trong `web/.env.example`):

| Tên | Giá trị |
|---|---|
| `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | Supabase |
| `SUPABASE_SERVICE_ROLE_KEY` | Service role key (Sensitive) |
| `APP_ORIGIN` | Địa chỉ staging |
| `DOCUMENT_STORAGE_PROVIDER` | `DRIVE` |
| `DRIVE_RUNTIME_VERIFIED` | `false` cho tới khi xong bước 6 |
| `DRIVE_GATEWAY_ORIGIN` | Địa chỉ `workers.dev` |
| `DRIVE_GRANT_SECRET`, `CRON_SECRET` | Giống Cloudflare |
| `DRIVE_WORKER_TOKEN` | Token `drive_storage_worker` |
| `STORAGE_CLEANUP_WORKER_TOKEN` | Token `storage_cleanup_worker` |
| `EMAIL_WORKER_TOKEN` | Token `email_worker` |
| `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` | Client *Desktop app* |
| `GMAIL_REFRESH_TOKEN` | Bước 1.6 (lệnh `gmail`) |

Tắt **Deployment Protection** cho bản staging, nếu không cron của Cloudflare bị chặn ở trang
đăng nhập của Vercel.

## 6. Nghiệm thu trước khi bật Drive

Đây là phần tôi làm cùng bạn. Chỉ khi cả bốn mục đạt mới đặt `DRIVE_RUNTIME_VERIFIED=true`
(Vercel) và `DRIVE_SCHEDULES_VERIFIED=true` (Cloudflare):

1. Upload một file PDF thật, xem trước và tải về đúng nội dung (AC-DRIVE-05).
2. Upload file mẫu virus **EICAR**: hệ thống phải báo file bị từ chối. Nếu Drive không bắt được,
   dừng lại — Owner chọn máy quét riêng hoặc bỏ định dạng `.doc`/`.ppt` (doc 102).
3. Upload file 5 MB và xem CPU của worker trong Cloudflare dashboard. Vượt 10 ms thì nâng gói
   5 USD/tháng.
4. Gửi một thư mời phỏng vấn: thư tới `test_sink`, Email History hiện `SENT`.

Sau đó chạy trọn luồng: OTP ứng viên → nộp phiếu có CV → HR mở phiếu, xem file → tạo
Application → lịch phỏng vấn → gửi thư → báo cáo.
