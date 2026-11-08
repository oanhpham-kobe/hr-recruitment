export default function NotFound() {
  return (
    <section
      className="not-found-container"
      aria-label="Trang không tìm thấy / Page not found"
    >
      <h1 className="not-found-title">
        404 - Không tìm thấy trang / Page Not Found
      </h1>
      <p className="not-found-desc">
        Địa chỉ bạn yêu cầu không tồn tại hoặc đã được di chuyển. Vui lòng quay
        lại trang chủ.
      </p>
      <a href="/" className="btn-primary">
        Quay lại trang chủ / Return home
      </a>
    </section>
  );
}
