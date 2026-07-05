-- Menu generator database
-- Target: PostgreSQL 13+
-- Stores each order ticket submitted through the interface, the menu
-- the workflow generated for it, and the price catalog used to estimate cost.

create extension if not exists "pgcrypto";

-- One row per submission from the order ticket form.
create table menu_orders (
    id                  uuid primary key default gen_random_uuid(),
    event_type          text not null,
    cuisine             text not null default 'Ugandan',
    guests              integer not null check (guests > 0),
    budget_per_plate    numeric(12, 2) not null check (budget_per_plate >= 0),
    estimated_cost      numeric(12, 2),
    over_budget         boolean generated always as (
                            estimated_cost is not null
                            and estimated_cost > budget_per_plate
                        ) stored,
    raw_menu_text       text,
    webhook_url         text,
    created_at          timestamptz not null default now()
);

create index idx_menu_orders_created_at on menu_orders (created_at desc);
create index idx_menu_orders_event_type on menu_orders (event_type);

-- One row per dish, tied back to the order it belongs to.
create type menu_course as enum (
    'starter', 'proteins', 'starches', 'vegetables', 'dessert'
);

create table menu_items (
    id            uuid primary key default gen_random_uuid(),
    order_id      uuid not null references menu_orders (id) on delete cascade,
    course        menu_course not null,
    item_name     text not null,
    position      integer not null default 0,
    unit_cost     numeric(12, 2)
);

create index idx_menu_items_order_id on menu_items (order_id);

-- Keyword pricing used by the "Estimate Cost" function node.
-- Kept in the database so prices can be updated without redeploying the workflow.
create table price_catalog (
    keyword       text primary key,
    unit_cost     numeric(12, 2) not null check (unit_cost >= 0),
    updated_at    timestamptz not null default now()
);

insert into price_catalog (keyword, unit_cost) values
    ('chicken', 12000),
    ('beef',    10000),
    ('matooke',  3000),
    ('rice',     4000),
    ('beans',    2000),
    ('greens',   1500),
    ('banana',   2000)
on conflict (keyword) do nothing;

-- Convenience view: one row per order with its items rolled up as JSON,
-- matching the shape the interface already renders.
create view menu_orders_with_items as
select
    o.id,
    o.event_type,
    o.cuisine,
    o.guests,
    o.budget_per_plate,
    o.estimated_cost,
    o.over_budget,
    o.created_at,
    coalesce(
        jsonb_object_agg(i.course, i.items) filter (where i.course is not null),
        '{}'::jsonb
    ) as items_by_course
from menu_orders o
left join (
    select
        order_id,
        course,
        jsonb_agg(item_name order by position) as items
    from menu_items
    group by order_id, course
) i on i.order_id = o.id
group by o.id;
