"use client";

import type { EducationItem } from "@/lib/commands/candidate-submission";

export interface QualificationLevelOption {
  id: string;
  code?: string;
  name: string;
}

interface EducationSectionProps {
  items: EducationItem[];
  onChange: (items: EducationItem[]) => void;
  qualificationLevels?: QualificationLevelOption[];
  disabled?: boolean;
}

export function EducationSection({
  items,
  onChange,
  qualificationLevels = [],
  disabled = false,
}: EducationSectionProps) {
  const handleAdd = () => {
    if (items.length >= 20) return;
    const newItem: EducationItem = {
      periodText: "",
      qualificationId: "",
      major: "",
      institution: "",
      sortOrder: items.length + 1,
    };
    onChange([...items, newItem]);
  };

  const handleRemove = (index: number) => {
    const updated = items
      .filter((_, idx) => idx !== index)
      .map((item, idx) => ({ ...item, sortOrder: idx + 1 }));
    onChange(updated);
  };

  const handleFieldChange = (
    index: number,
    field: keyof EducationItem,
    value: string | number | null,
  ) => {
    const updated = [...items];
    updated[index] = {
      ...updated[index],
      [field]: value,
    };
    onChange(updated);
  };

  return (
    <fieldset className="form-fieldset">
      <legend className="form-legend">
        B. Quá trình học tập / Education History (Không bắt buộc / Optional)
      </legend>

      {items.length === 0 ? (
        <p className="file-spec">
          Chưa có thông tin học tập. Nhấn nút bên dưới nếu bạn muốn bổ sung.
        </p>
      ) : (
        items.map((item, index) => (
          <div key={`edu-row-${item.sortOrder}`} className="education-item">
            <div className="education-header">
              <span className="education-title">Học vấn #{index + 1}</span>
              <button
                type="button"
                className="btn candidate-btn-danger btn-sm"
                onClick={() => handleRemove(index)}
                disabled={disabled}
                aria-label={`Xóa mục học vấn ${index + 1}`}
              >
                Xóa / Remove
              </button>
            </div>

            <div className="form-grid">
              {/* Period text */}
              <div className="form-group">
                <label className="form-label" htmlFor={`edu-period-${index}`}>
                  Thời gian / Period (VD: 2018 - 2022)
                </label>
                <input
                  id={`edu-period-${index}`}
                  name={`education[${index}].periodText`}
                  type="text"
                  className="form-input"
                  value={item.periodText ?? ""}
                  onChange={(e) =>
                    handleFieldChange(index, "periodText", e.target.value)
                  }
                  placeholder="2018 - 2022"
                  maxLength={100}
                  disabled={disabled}
                />
              </div>

              {/* Qualification Level */}
              <div className="form-group">
                <label className="form-label" htmlFor={`edu-qual-${index}`}>
                  Trình độ đào tạo / Qualification
                </label>
                <select
                  id={`edu-qual-${index}`}
                  name={`education[${index}].qualificationId`}
                  className="form-select"
                  value={item.qualificationId ?? ""}
                  onChange={(e) =>
                    handleFieldChange(
                      index,
                      "qualificationId",
                      e.target.value || null,
                    )
                  }
                  disabled={disabled}
                >
                  <option value="">-- Chọn trình độ / Select level --</option>
                  {qualificationLevels.map((lvl) => (
                    <option key={lvl.id} value={lvl.id}>
                      {lvl.name}
                    </option>
                  ))}
                </select>
              </div>

              {/* Major */}
              <div className="form-group">
                <label className="form-label" htmlFor={`edu-major-${index}`}>
                  Chuyên ngành / Major
                </label>
                <input
                  id={`edu-major-${index}`}
                  name={`education[${index}].major`}
                  type="text"
                  className="form-input"
                  value={item.major ?? ""}
                  onChange={(e) =>
                    handleFieldChange(index, "major", e.target.value)
                  }
                  placeholder="Khoa học máy tính / Computer Science"
                  maxLength={255}
                  disabled={disabled}
                />
              </div>

              {/* Institution */}
              <div className="form-group">
                <label className="form-label" htmlFor={`edu-inst-${index}`}>
                  Trường đào tạo / Institution
                </label>
                <input
                  id={`edu-inst-${index}`}
                  name={`education[${index}].institution`}
                  type="text"
                  className="form-input"
                  value={item.institution ?? ""}
                  onChange={(e) =>
                    handleFieldChange(index, "institution", e.target.value)
                  }
                  placeholder="Đại học Quốc tế Miền Đông / EIU"
                  maxLength={255}
                  disabled={disabled}
                />
              </div>
            </div>
          </div>
        ))
      )}

      <button
        type="button"
        className="btn btn-secondary"
        onClick={handleAdd}
        disabled={disabled || items.length >= 20}
        style={{ marginTop: "12px" }}
      >
        + Thêm quá trình học tập / Add Education
      </button>
    </fieldset>
  );
}
