"use client";

import type React from "react";
import { useState } from "react";
import { Header } from "./Header";
import { LocaleProvider } from "./LocaleProvider";
import { MobileNavigation } from "./MobileNavigation";
import type { NavItem } from "./navigation";
import { Sidebar } from "./Sidebar";
import { SkipLink } from "./SkipLink";

export interface AppShellProps {
  children: React.ReactNode;
  title?: React.ReactNode;
  currentPath?: string;
  navItems?: readonly NavItem[];
  /** Optional demo workspace UI. This slot supplies no application authority. */
  workspaceControl?: React.ReactNode;
  accountLabel?: string;
}

function AppShellContent({
  children,
  title,
  currentPath = "/",
  navItems = [],
  workspaceControl,
  accountLabel,
}: AppShellProps) {
  const [mobileNavOpen, setMobileNavOpen] = useState(false);

  return (
    <div className="shell">
      <SkipLink />
      <Sidebar
        currentPath={currentPath}
        navItems={navItems}
        accountLabel={accountLabel}
      />
      <MobileNavigation
        open={mobileNavOpen}
        currentPath={currentPath}
        navItems={navItems}
        onClose={() => setMobileNavOpen(false)}
        accountLabel={accountLabel}
      />
      <div className="shell-main">
        <Header
          title={title}
          workspaceControl={workspaceControl}
          mobileNavOpen={mobileNavOpen}
          onOpenNavigation={() => setMobileNavOpen(true)}
        />
        <main id="main-content" tabIndex={-1} className="content">
          {children}
        </main>
      </div>
    </div>
  );
}

export function AppShell(props: AppShellProps) {
  return (
    <LocaleProvider>
      <AppShellContent {...props} />
    </LocaleProvider>
  );
}
