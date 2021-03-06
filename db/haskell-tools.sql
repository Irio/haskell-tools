CREATE DATABASE haskell_tools;

\c haskell_tools
CREATE EXTENSION unaccent;
CREATE EXTENSION pg_trgm;
-- Private data structures

CREATE TABLE public.packages (
  package_name text PRIMARY KEY,
  version text NOT NULL,
  license text NOT NULL,
  description text NOT NULL,
  category text NOT NULL,
  homepage text NOT NULL,
  package_url text NOT NULL,
  repo_type text,
  repo_location text,
  created_at timestamp NOT NULL default current_timestamp,
  updated_at timestamp NOT NULL default current_timestamp
);

CREATE TABLE public.repos (
  package_name text PRIMARY KEY REFERENCES packages,
  stars integer NOT NULL DEFAULT 0,
  forks integer NOT NULL DEFAULT 0,
  collaborators integer NOT NULL DEFAULT 1,
  created_at timestamp NOT NULL default current_timestamp,
  updated_at timestamp NOT NULL default current_timestamp
);

CREATE TABLE public.dependencies (
  dependent text REFERENCES public.packages (package_name),
  dependency text REFERENCES public.packages (package_name),
  version_range text,
  created_at timestamp NOT NULL default current_timestamp,
  updated_at timestamp NOT NULL default current_timestamp,
  PRIMARY KEY (dependent, dependency)
);

CREATE TABLE public.extensions (
  package_name text REFERENCES public.packages (package_name),
  extension text,
  created_at timestamp NOT NULL default current_timestamp,
  updated_at timestamp NOT NULL default current_timestamp,
  PRIMARY KEY (package_name, extension)
);

-- Triggers to update updated_at columns
CREATE FUNCTION public.update_updated_at()
RETURNS TRIGGER
LANGUAGE 'plpgsql'
AS $$
BEGIN
  NEW.updated_at := current_timestamp;
  RETURN NEW;
END;
$$;

CREATE TRIGGER update_updated_at
BEFORE UPDATE ON public.packages
FOR EACH ROW
EXECUTE PROCEDURE update_updated_at();

CREATE TRIGGER update_updated_at
BEFORE UPDATE ON public.dependencies
FOR EACH ROW
EXECUTE PROCEDURE update_updated_at();

CREATE TRIGGER update_updated_at
BEFORE UPDATE ON public.extensions
FOR EACH ROW
EXECUTE PROCEDURE update_updated_at();

CREATE TRIGGER update_updated_at
BEFORE UPDATE ON public.repos
FOR EACH ROW
EXECUTE PROCEDURE update_updated_at();

CREATE VIEW public.package_repos AS
SELECT
  p.package_name,
  r[1] as owner,
  r[2] as repo
FROM
  packages p,
  regexp_matches(repo_location, 'github.com[:\/]([^\/]*)\/([^\. ]*)') r
WHERE
  repo_location ~* 'github';

CREATE OR REPLACE VIEW public.categories AS
SELECT
  p.package_name,
  initcap(btrim(translate(c.c, chr(10) || chr(13), ''))) AS category_name
FROM
  packages p,
  LATERAL regexp_split_to_table(p.category, ','::text) c(c)
WHERE
  btrim(c.c) <> ''::text;

-- API exposed through PostgREST
CREATE SCHEMA api;

CREATE OR REPLACE VIEW api.packages AS
SELECT
  p.package_name,
  p.version,
  p.license,
  p.description,
  p.category,
  p.homepage,
  p.package_url,
  p.repo_type,
  p.repo_location,
  r.stars,
  r.forks,
  r.collaborators,
  (
    SELECT coalesce(json_agg(DISTINCT e.extension), '[]')
    FROM extensions e
    WHERE e.extension IS NOT NULL AND e.package_name = p.package_name
  ) AS extensions,
  (
    SELECT coalesce(json_agg(d.dependency), '[]')
    FROM dependencies d
    WHERE d.dependency IS NOT NULL AND d.dependent = p.package_name
  ) AS dependencies,
  (
    SELECT coalesce(json_agg(d.dependent), '[]')
    FROM dependencies d
    WHERE d.dependent IS NOT NULL AND d.dependency = p.package_name
  ) AS dependents,
  -- when querying created at we usually want to know when it first got into our database
  LEAST(p.created_at, r.created_at) as created_at,
  -- when querying created at we usually want to know when it was last updated
  GREATEST(p.updated_at, r.updated_at) as updated_at
FROM
  packages p
  JOIN repos r USING (package_name)
GROUP BY
  p.package_name, r.package_name;

CREATE OR REPLACE FUNCTION api.package_search(query text)
   RETURNS SETOF api.packages
   LANGUAGE sql
   STABLE
  AS $function$
  SELECT
      p.*
  FROM
      api.packages p
  WHERE
      to_tsvector(p.description) @@ plainto_tsquery(unaccent(query))
      OR
      p.package_name % query
  ORDER BY
      ts_rank( setweight(to_tsvector(p.package_name), 'A') || setweight(to_tsvector(p.description), 'B')
             , plainto_tsquery(unaccent(query))
             ) DESC;
  $function$;

CREATE OR REPLACE VIEW api.extensions AS
SELECT
  extension,
  count(distinct package_name) AS packages
FROM
  extensions
GROUP BY
  extension;

CREATE MATERIALIZED VIEW api.dependency_tree AS
WITH RECURSIVE dependency_tree AS (
  SELECT package_name, package_name as parent, 1 as deps FROM api.packages
  UNION
  SELECT t.package_name, d.dependency as parent, 1 as deps FROM public.dependencies d JOIN dependency_tree t ON d.dependent = t.parent
),
dependent_tree AS (
  SELECT package_name, package_name as parent, 0 as deps FROM api.packages
  UNION
  SELECT t.package_name, d.dependent as parent, 1 as deps FROM public.dependencies d JOIN dependent_tree t ON d.dependency = t.parent
),
totals AS (
  SELECT package_name, ty.sum as all_dependencies, tt.sum as all_dependents
  FROM
  (SELECT package_name, sum(deps) FROM dependency_tree GROUP BY package_name) ty
  JOIN
  (SELECT package_name, sum(deps) FROM dependent_tree GROUP BY package_name) tt
  USING (package_name)
)
SELECT
  p.package_name,
  p.stars,
  p.forks,
  p.collaborators,
  all_dependencies,
  all_dependents,
  all_dependents / all_dependencies::numeric as ratio
FROM
  totals JOIN api.packages p USING (package_name);

CREATE USER postgrest PASSWORD :password;
CREATE ROLE anonymous;
GRANT anonymous TO postgrest;
GRANT USAGE ON SCHEMA api TO anonymous;
GRANT EXECUTE ON FUNCTION api.package_search(text) TO anonymous;
GRANT SELECT ON ALL TABLES IN SCHEMA api TO anonymous;
