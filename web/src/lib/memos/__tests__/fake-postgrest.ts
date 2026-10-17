// Synthetic in-memory PostgREST double. Applies real filter semantics
// (eq/is/in/gte/lt/imatch/or + order + limit) over plain rows so the Supabase
// repository code is exercised behaviorally — ownership predicates, tombstone
// filters, keyset cursors and literal substring search all have observable effects here.

export interface FakeRow {
  [column: string]: unknown;
}

interface Filter {
  test(row: FakeRow): boolean;
}

interface OrderSpec {
  column: string;
  ascending: boolean;
  nullsFirst: boolean;
}

/**
 * Synthetic FK relationship so embedded-relation queries
 * (`memo_tag_links!inner(label)` + qualified filters like
 * `memo_tag_links.label=eq.…`) have real observable semantics here — the
 * qualified relation filter must restrict PARENT rows in the database, before
 * order/limit, exactly as PostgREST does with a composite foreign key.
 */
export interface FakeRelation {
  /** Table on the many side of the relationship (e.g. memo_tag_links). */
  childTable: string;
  /** Parent table the embed attaches to (e.g. memos). */
  parentTable: string;
  /** [parentColumn, childColumn] pairs (composite FK aware). */
  columns: ReadonlyArray<[string, string]>;
}

interface EmbedSpec {
  alias: string;
  relation: FakeRelation;
  inner: boolean;
  columns: string[];
}

export interface FakeCall {
  table: string;
  op: string;
  detail?: unknown;
}

const TIMESTAMP_RE =
  /^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2}:\d{2})(?:\.(\d{1,6}))?(Z|[+-]\d{2}:\d{2})$/;

/** Canonical UTC `YYYY-MM-DDTHH:MM:SS.ffffff` — microsecond aware. */
function canonicalTimestamp(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const match = TIMESTAMP_RE.exec(value);
  if (!match) return null;
  const [, date, time, frac, zone] = match;
  const epoch = Date.parse(`${date}T${time}${zone === "Z" ? "Z" : zone}`);
  if (Number.isNaN(epoch)) return null;
  return `${new Date(epoch).toISOString().slice(0, 19)}.${(frac ?? "0").padEnd(6, "0")}`;
}

/**
 * Postgres `text COLLATE "C"` orders text by UTF-8 BYTES, not by JavaScript
 * UTF-16 code units — the two disagree at the BMP/astral boundary (e.g. `#\uE000`
 * sorts BEFORE `#😀` in C). Implemented here independently of the production
 * comparator so the double exercises real C ordering in its filter/order
 * semantics and cannot hide a keyset-guard bug.
 */
function compareTextC(a: string, b: string): number {
  return Buffer.compare(Buffer.from(a, "utf8"), Buffer.from(b, "utf8"));
}

function compareValues(a: unknown, b: unknown): number {
  const ta = canonicalTimestamp(a);
  const tb = canonicalTimestamp(b);
  if (ta !== null && tb !== null) return ta < tb ? -1 : ta > tb ? 1 : 0;
  if (typeof a === "number" && typeof b === "number") return a - b;
  return compareTextC(String(a), String(b));
}

function unquoteFilterValue(raw: string): string {
  if (raw.length >= 2 && raw.startsWith('"') && raw.endsWith('"')) {
    return raw
      .slice(1, -1)
      .replace(/\\(["\\])/g, (_m, ch: string) => ch);
  }
  return raw;
}

function splitTopLevel(input: string): string[] {
  const parts: string[] = [];
  let depth = 0;
  let inQuotes = false;
  let current = "";
  for (let i = 0; i < input.length; i += 1) {
    const ch = input[i];
    if (inQuotes) {
      if (ch === "\\" && i + 1 < input.length) {
        current += ch + input[i + 1];
        i += 1;
        continue;
      }
      if (ch === '"') inQuotes = false;
      current += ch;
      continue;
    }
    if (ch === '"') {
      inQuotes = true;
      current += ch;
      continue;
    }
    if (ch === "(") depth += 1;
    if (ch === ")") depth -= 1;
    if (ch === "," && depth === 0) {
      parts.push(current);
      current = "";
      continue;
    }
    current += ch;
  }
  if (current.length > 0) parts.push(current);
  return parts.map((part) => part.trim()).filter((part) => part.length > 0);
}

const TERM_RE = /^([a-z_]+)\.(eq|neq|lt|lte|gt|gte)\.([\s\S]+)$/;

function parseFilterTerm(input: string): Filter {
  const trimmed = input.trim();
  if (trimmed.startsWith("and(") && trimmed.endsWith(")")) {
    const inner = splitTopLevel(trimmed.slice(4, -1)).map(parseFilterTerm);
    return { test: (row) => inner.every((filter) => filter.test(row)) };
  }
  if (trimmed.startsWith("or(") && trimmed.endsWith(")")) {
    const inner = splitTopLevel(trimmed.slice(3, -1)).map(parseFilterTerm);
    return { test: (row) => inner.some((filter) => filter.test(row)) };
  }
  const match = TERM_RE.exec(trimmed);
  if (!match) throw new Error(`fake-postgrest: cannot parse filter term: ${trimmed}`);
  const [, column, operator, rawValue] = match;
  const value = unquoteFilterValue(rawValue);
  return {
    test: (row) => {
      const cmp = compareValues(row[column], value);
      switch (operator) {
        case "eq":
          return canonicalTimestamp(row[column]) !== null && canonicalTimestamp(value) !== null
            ? canonicalTimestamp(row[column]) === canonicalTimestamp(value)
            : String(row[column]) === value;
        case "neq":
          return String(row[column]) !== value;
        case "lt":
          return cmp < 0;
        case "lte":
          return cmp <= 0;
        case "gt":
          return cmp > 0;
        case "gte":
          return cmp >= 0;
        default:
          return false;
      }
    },
  };
}

class FakeBuilder implements PromiseLike<{ data: unknown; error: { message: string } | null }> {
  private filters: Filter[] = [];
  private orders: OrderSpec[] = [];
  private limitCount: number | null = null;
  private embeds: EmbedSpec[] = [];
  private childFilters = new Map<string, Filter[]>();

  constructor(
    private readonly db: FakePostgrest,
    private readonly table: string,
  ) {
    db.record(this.table, "from");
  }

  /**
   * Route `relation.column` filters to the embedded relation's rows. Parent
   * restriction happens in resolveRows (inner semantics), mirroring PostgREST
   * `!inner` qualified filtering.
   */
  private routeFilter(column: string, make: (plain: string) => Filter): Filter {
    const dot = column.indexOf(".");
    if (dot === -1) return make(column);
    const name = column.slice(0, dot);
    const childColumn = column.slice(dot + 1);
    const relation = this.db.relationFor(this.table, name);
    if (!relation) throw new Error(`fake-postgrest: unknown relation ${name}`);
    const filter = make(childColumn);
    const list = this.childFilters.get(name) ?? [];
    list.push(filter);
    this.childFilters.set(name, list);
    // Parent matching is decided through the relation join in resolveRows.
    return { test: () => true };
  }

  select(projection: string): this {
    this.db.record(this.table, "projection", projection);
    for (const segment of splitTopLevel(projection)) {
      const match = /^([a-z_]+)(!inner)?\(([^)]*)\)$/.exec(segment);
      if (!match) continue;
      const [, name, inner, cols] = match;
      const relation = this.db.relationFor(this.table, name);
      if (!relation) throw new Error(`fake-postgrest: unknown relation ${name}`);
      this.embeds.push({
        alias: name,
        relation,
        inner: Boolean(inner),
        columns: cols
          .split(",")
          .map((c) => c.trim())
          .filter((c) => c.length > 0),
      });
    }
    return this;
  }

  eq(column: string, value: unknown): this {
    this.filters.push(
      this.routeFilter(column, (plain) => ({
        test: (row) => String(row[plain]) === String(value),
      })),
    );
    return this;
  }

  is(column: string, value: null): this {
    if (value !== null) throw new Error("fake-postgrest: only `is null` supported");
    this.filters.push(
      this.routeFilter(column, (plain) => ({
        test: (row) => row[plain] === null || row[plain] === undefined,
      })),
    );
    return this;
  }

  in(column: string, values: readonly string[]): this {
    const set = new Set(values.map(String));
    this.filters.push(
      this.routeFilter(column, (plain) => ({
        test: (row) => set.has(String(row[plain])),
      })),
    );
    return this;
  }

  gte(column: string, value: string): this {
    this.filters.push(this.routeFilter(column, (plain) => parseFilterTerm(`${plain}.gte.${quoteIfNeeded(value)}`)));
    return this;
  }

  gt(column: string, value: string): this {
    this.filters.push(this.routeFilter(column, (plain) => parseFilterTerm(`${plain}.gt.${quoteIfNeeded(value)}`)));
    return this;
  }

  lt(column: string, value: string): this {
    this.filters.push(this.routeFilter(column, (plain) => parseFilterTerm(`${plain}.lt.${quoteIfNeeded(value)}`)));
    return this;
  }

  filter(column: string, operator: string, value: string): this {
    if (operator !== "imatch" || !value.startsWith("***=")) {
      throw new Error("fake-postgrest: only literal imatch supported");
    }
    const literal = value.slice(4).toLowerCase();
    this.filters.push(
      this.routeFilter(column, (plain) => ({
        test: (row) => String(row[plain] ?? "").toLowerCase().includes(literal),
      })),
    );
    return this;
  }

  or(filters: string): this {
    const terms = splitTopLevel(filters).map(parseFilterTerm);
    this.filters.push({ test: (row) => terms.some((filter) => filter.test(row)) });
    return this;
  }

  order(column: string, options?: { ascending?: boolean; nullsFirst?: boolean }): this {
    this.orders.push({
      column,
      ascending: options?.ascending ?? true,
      nullsFirst: options?.nullsFirst ?? true,
    });
    return this;
  }

  limit(count: number): this {
    this.limitCount = count;
    return this;
  }

  private resolveRows(): FakeRow[] {
    let rows = (this.db.table(this.table) ?? []).filter((row) =>
      this.filters.every((filter) => filter.test(row)),
    );

    // Embedded-relation resolution: qualified filters restrict PARENT rows
    // (inner semantics) before ordering/limit, and embeds project child rows.
    const relationNames = new Set<string>([
      ...this.childFilters.keys(),
      ...this.embeds.map((e) => e.alias),
    ]);
    if (relationNames.size > 0) {
      // Index child rows per relation once — same join semantics, bounded cost.
      const childIndex = new Map<string, Map<string, FakeRow[]>>();
      const indexFor = (relation: FakeRelation): Map<string, FakeRow[]> => {
        const cacheKey = `${relation.parentTable}:${relation.childTable}`;
        let index = childIndex.get(cacheKey);
        if (!index) {
          index = new Map<string, FakeRow[]>();
          for (const child of this.db.table(relation.childTable) ?? []) {
            const key = relation.columns
              .map(([, childCol]) => String(child[childCol]))
              .join("\u0000");
            const list = index.get(key);
            if (list) list.push(child);
            else index.set(key, [child]);
          }
          childIndex.set(cacheKey, index);
        }
        return index;
      };

      const resolved: FakeRow[] = [];
      for (const row of rows) {
        const out: FakeRow = this.embeds.length > 0 ? { ...row } : row;
        let keep = true;
        for (const name of relationNames) {
          const embed = this.embeds.find((e) => e.alias === name) ?? null;
          const relation = embed ? embed.relation : this.db.relationFor(this.table, name);
          if (!relation) throw new Error(`fake-postgrest: unknown relation ${name}`);
          const filters = this.childFilters.get(name) ?? [];
          const parentKey = relation.columns
            .map(([parentCol]) => String(row[parentCol]))
            .join("\u0000");
          const children = (indexFor(relation).get(parentKey) ?? []).filter((child) =>
            filters.every((filter) => filter.test(child)),
          );
          if (children.length === 0 && (embed ? embed.inner : true)) {
            keep = false;
            break;
          }
          if (embed) {
            out[embed.alias] = children.map((child) => projectColumns(child, embed.columns));
          }
        }
        if (keep) resolved.push(out);
      }
      rows = resolved;
    }

    rows.sort((a, b) => {
      for (const order of this.orders) {
        const av = a[order.column];
        const bv = b[order.column];
        const aNull = av === null || av === undefined;
        const bNull = bv === null || bv === undefined;
        if (aNull !== bNull) {
          if (aNull) return order.nullsFirst ? -1 : 1;
          return order.nullsFirst ? 1 : -1;
        }
        if (!aNull) {
          const cmp = compareValues(av, bv);
          if (cmp !== 0) return order.ascending ? cmp : -cmp;
        }
      }
      return 0;
    });
    return this.limitCount === null ? rows : rows.slice(0, this.limitCount);
  }

  maybeSingle(): PromiseLike<{ data: unknown; error: { message: string } | null }> {
    this.db.record(this.table, "maybeSingle");
    const rows = this.resolveRows();
    return Promise.resolve({
      data: rows.length > 0 ? rows[0] : null,
      error: rows.length > 1 ? { message: "multiple rows" } : null,
    });
  }

  then<TResult1 = { data: unknown; error: { message: string } | null }, TResult2 = never>(
    onfulfilled?: ((value: { data: unknown; error: { message: string } | null }) => TResult1 | PromiseLike<TResult1>) | null,
    onrejected?: ((reason: unknown) => TResult2 | PromiseLike<TResult2>) | null,
  ): PromiseLike<TResult1 | TResult2> {
    return Promise.resolve({ data: this.resolveRows(), error: null }).then(onfulfilled, onrejected);
  }
}

function quoteIfNeeded(value: string): string {
  return /[,()"]/.test(value) ? `"${value.replace(/(["\\])/g, "\\$1")}"` : `"${value}"`;
}

function projectColumns(row: FakeRow, columns: string[]): FakeRow {
  if (columns.length === 0 || columns.includes("*")) return { ...row };
  const projected: FakeRow = {};
  for (const column of columns) projected[column] = row[column];
  return projected;
}

export class FakePostgrest {
  private tables = new Map<string, FakeRow[]>();
  private relations: FakeRelation[] = [];
  calls: FakeCall[] = [];

  constructor(tables: Record<string, FakeRow[]>, relations: FakeRelation[] = []) {
    for (const [name, rows] of Object.entries(tables)) {
      this.tables.set(name, rows);
    }
    this.relations = relations;
  }

  table(name: string): FakeRow[] | undefined {
    return this.tables.get(name);
  }

  relationFor(parentTable: string, childTable: string): FakeRelation | null {
    return (
      this.relations.find(
        (r) => r.parentTable === parentTable && r.childTable === childTable,
      ) ?? null
    );
  }

  record(table: string, op: string, detail?: unknown): void {
    this.calls.push({ table, op, detail });
  }

  countCalls(table: string, op?: string): number {
    return this.calls.filter((c) => c.table === table && (!op || c.op === op)).length;
  }

  from(table: string): FakeBuilder {
    return new FakeBuilder(this, table);
  }
}
