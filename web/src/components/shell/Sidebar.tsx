"use client";

import { Brand } from "./Brand";
import { useAppLocale } from "./LocaleProvider";
import { NavigationIcon } from "./NavigationIcon";
import type { NavItem } from "./navigation";

export interface SidebarProps {
  currentPath?: string;
  navItems: readonly NavItem[];
  accountLabel?: string;
}

export function Sidebar({
  currentPath = "/",
  navItems,
  accountLabel,
}: SidebarProps) {
  const { locale } = useAppLocale();

  return (
    <aside
      className="sidebar"
      aria-label={locale === "vi" ? "Thanh điều hướng chính" : "Main sidebar"}
    >
      <div className="sidebar-brand">
        <Brand />
        <div className="brand-sub">
          {locale === "vi" ? "Tuyển dụng" : "Recruitment"}
        </div>
      </div>

      <nav
        className="sidebar-nav"
        aria-label={locale === "vi" ? "Menu chức năng" : "Navigation menu"}
      >
        <p className="sidebar-section-label">
          {locale === "vi" ? "Không gian làm việc" : "Workspace"}
        </p>
        <ul className="nav-list">
          {navItems.map((item) => {
            const isCurrent = currentPath === item.href;
            return (
              <li key={item.href} className="nav-item">
                <a
                  href={item.href}
                  aria-current={isCurrent ? "page" : undefined}
                >
                  <NavigationIcon path={item.href} />
                  <span>{locale === "vi" ? item.labelVi : item.labelEn}</span>
                </a>
              </li>
            );
          })}
        </ul>
      </nav>

      <div className="sidebar-user">
        <div
          className="user-avatar"
          role="img"
          aria-label={
            locale === "vi" ? "Ảnh đại diện người dùng" : "User avatar"
          }
        >
          IU
        </div>
        <div className="user-info">
          <span className="user-name">
            {accountLabel ??
              (locale === "vi" ? "Người dùng nội bộ" : "Internal User")}
          </span>
          <span className="user-role">EIU Recruitment</span>
        </div>
      </div>
    </aside>
  );
}
