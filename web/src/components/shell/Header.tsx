"use client";

import type React from "react";
import { useAppLocale } from "./LocaleProvider";
import { NavigationIcon } from "./NavigationIcon";

export interface HeaderProps {
  title?: React.ReactNode;
  mobileNavOpen?: boolean;
  onOpenNavigation?: () => void;
  workspaceControl?: React.ReactNode;
}

export function Header({
  title,
  mobileNavOpen = false,
  onOpenNavigation,
  workspaceControl,
}: HeaderProps) {
  const { locale, setLocale } = useAppLocale();
  const defaultTitle =
    locale === "vi" ? "Hệ thống Tuyển dụng EIU" : "EIU Recruitment";

  return (
    <header className="topbar">
      <button
        id="internal-nav-trigger"
        type="button"
        className="internal-nav-trigger"
        aria-label={locale === "vi" ? "Mở menu" : "Open navigation"}
        aria-expanded={mobileNavOpen}
        aria-controls="mobile-internal-navigation"
        onClick={onOpenNavigation}
      >
        <NavigationIcon path="menu" />
      </button>
      <div className="topbar-title">
        {typeof title === "string" ? (
          <h1>{title}</h1>
        ) : title ? (
          title
        ) : (
          <span className="workspace-product">{defaultTitle}</span>
        )}
      </div>
      <div className="topbar-utility">
        {workspaceControl}
        <fieldset className="language-switcher">
          <legend className="sr-only">
            {locale === "vi" ? "Chọn ngôn ngữ" : "Choose language"}
          </legend>
          <button
            type="button"
            className={`lang-btn ${locale === "vi" ? "active" : ""}`.trim()}
            aria-pressed={locale === "vi"}
            aria-label={
              locale === "vi" ? "Tiếng Việt, đang chọn" : "Vietnamese"
            }
            onClick={() => setLocale("vi")}
          >
            VI
          </button>
          <span className="lang-divider" aria-hidden="true">
            |
          </span>
          <button
            type="button"
            className={`lang-btn ${locale === "en" ? "active" : ""}`.trim()}
            aria-pressed={locale === "en"}
            aria-label={locale === "en" ? "English, selected" : "Tiếng Anh"}
            onClick={() => setLocale("en")}
          >
            EN
          </button>
        </fieldset>
      </div>
    </header>
  );
}
