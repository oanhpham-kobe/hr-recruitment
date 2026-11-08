import { useState } from "react";
import { createRoot } from "react-dom/client";
import { Dialog } from "@/components/ui/Dialog";
import { Drawer } from "@/components/ui/Drawer";
import { StatusMenu } from "@/components/ui/StatusMenu";
import "@/app/globals.css";

function Harness() {
  const [status, setStatus] = useState("READ");
  const [drawerOpen, setDrawerOpen] = useState(false);
  const [dialogOpen, setDialogOpen] = useState(false);

  return (
    <div data-testid="primitive-harness-ready">
      <StatusMenu
        label={`Trạng thái: ${status}`}
        currentValue={status}
        options={[
          { value: "NEW", label: "Mới" },
          { value: "READ", label: "Đã đọc" },
          { value: "DONE", label: "Hoàn thành", disabled: true },
          { value: "CLOSED", label: "Đã đóng" },
        ]}
        onSelect={setStatus}
      />

      <button
        type="button"
        data-testid="open-drawer"
        onClick={() => setDrawerOpen(true)}
      >
        Mở Drawer
      </button>

      <Drawer
        open={drawerOpen}
        title="Drawer nền"
        onClose={() => setDrawerOpen(false)}
        footer={
          <button
            type="button"
            data-testid="open-dialog"
            onClick={() => setDialogOpen(true)}
          >
            Mở Dialog
          </button>
        }
      >
        <p>Nội dung Drawer</p>
        {Array.from({ length: 12 }, (_, i) => `Mục ${i + 1}`).map((label) => (
          <label key={label} style={{ display: "grid", marginBottom: 16 }}>
            {label} — Ghi chú phỏng vấn / Interview notes
            <textarea rows={3} />
          </label>
        ))}
      </Drawer>

      <Dialog
        open={dialogOpen}
        title="Xác nhận"
        onClose={() => setDialogOpen(false)}
        footer={
          <button type="button" onClick={() => setDialogOpen(false)}>
            Đồng ý
          </button>
        }
      >
        <p>Dialog nằm trên Drawer.</p>
        {Array.from({ length: 12 }, (_, i) => `Trường ${i + 1}`).map(
          (label) => (
            <label key={label} style={{ display: "grid", marginBottom: 16 }}>
              {label} — Nội dung xác nhận / Confirmation details
              <input type="text" />
            </label>
          ),
        )}
      </Dialog>
    </div>
  );
}

const rootElement = document.getElementById("root");
if (!rootElement) {
  throw new Error("Primitive interaction root element is missing");
}
createRoot(rootElement).render(<Harness />);
