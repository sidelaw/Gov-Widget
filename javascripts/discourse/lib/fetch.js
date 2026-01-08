export async function fetchJson(url, options) {
  const response = await fetch(url, {
    ...options,
    cache: "no-cache",
    mode: "cors",
    credentials: "omit",
  });

  if (!response.ok) {
    throw new Error(`HTTP ${response.status}: ${response.statusText}`);
  }

  return response.json();
}
