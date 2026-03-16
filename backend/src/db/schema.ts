import { sqliteTable, text, integer, real } from "drizzle-orm/sqlite-core";

export const users = sqliteTable("users", {
  id: text("id").primaryKey(), // UUID
  googleId: text("google_id").notNull().unique(),
  displayName: text("display_name").notNull(),
  avatarUrl: text("avatar_url"),
  createdAt: integer("created_at", { mode: "timestamp" })
    .notNull()
    .$defaultFn(() => new Date()),
});

export const territories = sqliteTable("territories", {
  id: text("id").primaryKey(), // UUID
  userId: text("user_id")
    .notNull()
    .references(() => users.id),
  // GeoJSON Polygon stored as JSON string
  polygonGeojson: text("polygon_geojson").notNull(),
  areaSqm: real("area_sqm").notNull(),
  // Which admin region this territory belongs to
  municipalityId: text("municipality_id").references(() => adminRegions.id),
  districtId: text("district_id").references(() => adminRegions.id),
  cantonId: text("canton_id").references(() => adminRegions.id),
  countryId: text("country_id").references(() => adminRegions.id),
  active: integer("active", { mode: "boolean" }).notNull().default(true),
  createdAt: integer("created_at", { mode: "timestamp" })
    .notNull()
    .$defaultFn(() => new Date()),
});

// Administrative regions (Gemeinde, Bezirk, Kanton, Land)
export const adminRegions = sqliteTable("admin_regions", {
  id: text("id").primaryKey(), // OSM relation ID or custom
  osmId: integer("osm_id"),
  name: text("name").notNull(),
  level: text("level", {
    enum: ["municipality", "district", "canton", "country"],
  }).notNull(),
  parentId: text("parent_id"), // self-reference for hierarchy
  // Boundary polygon as GeoJSON (simplified for performance)
  boundaryGeojson: text("boundary_geojson"),
  countryCode: text("country_code"), // e.g. "CH", "DE", "AT"
});

export const rankings = sqliteTable("rankings", {
  id: text("id").primaryKey(),
  userId: text("user_id")
    .notNull()
    .references(() => users.id),
  regionId: text("region_id")
    .notNull()
    .references(() => adminRegions.id),
  totalAreaSqm: real("total_area_sqm").notNull().default(0),
  rank: integer("rank"),
  updatedAt: integer("updated_at", { mode: "timestamp" })
    .notNull()
    .$defaultFn(() => new Date()),
});
