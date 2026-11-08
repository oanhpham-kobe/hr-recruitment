/** One outline family for navigation; labels carry the accessible meaning. */
export function NavigationIcon({ path }: { path: string }) {
  const paths: Record<string, string> = {
    "/": "M4 4h16v16H4z M4 13h5l2 3h2l2-3h5 M8 8h8",
    "/interviews":
      "M5 5h14v15H5z M8 3v4 M16 3v4 M5 10h14 M9 14h2 M14 14h2 M9 17h2",
    "/reports": "M6 3h9l4 4v14H6z M14 3v5h5 M9 12h7 M9 16h7",
    "/interview-feedback": "M4 4h16v12h-8l-5 4v-4H4z M8 8h8 M8 12h5",
    "/users":
      "M15 20v-2a4 4 0 0 0-4-4H7a4 4 0 0 0-4 4v2 M9 10a3 3 0 1 0 0-6 3 3 0 0 0 0 6 M17 5a3 3 0 0 1 0 6 M21 20v-2a4 4 0 0 0-3-4",
    "/master-data": "M4 4h6v6H4z M14 4h6v6h-6z M4 14h6v6H4z M14 14h6v6h-6z",
    "/candidate":
      "M15 20v-2a4 4 0 0 0-4-4H7a4 4 0 0 0-4 4v2 M9 10a3 3 0 1 0 0-6 3 3 0 0 0 0 6 M17 11l2 2 3-4",
    "/guide":
      "M4 4h6a3 3 0 0 1 3 3v14a3 3 0 0 0-3-3H4z M13 7a3 3 0 0 1 3-3h5v14h-5a3 3 0 0 0-3 3",
    "/services": "M3 5h18v14H3z M3 6l9 7 9-7",
    preview:
      "M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12 M15 12a3 3 0 1 0-6 0 3 3 0 0 0 6 0",
    download: "M12 3v12 M7 10l5 5 5-5 M4 16v5h16v-5",
    menu: "M4 6h16 M4 12h16 M4 18h16",
    workspace: "M4 7h16v13H4z M8 7V4h8v3 M4 12h16 M10 12v3h4v-3",
  };
  return (
    <svg
      className="navigation-icon"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.7"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d={paths[path] ?? paths["/"]} />
    </svg>
  );
}
