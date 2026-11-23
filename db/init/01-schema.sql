-- Схема демо-магазина для стенда Docker.

create table categories (
    id serial primary key,
    name varchar(64) not null unique
);

create table products (
    id serial primary key,
    name varchar(120) not null,
    category_id int not null references categories (id),
    price numeric(10, 2) not null check (price >= 0),
    stock int not null default 0 check (stock >= 0),
    created_at timestamptz not null default now()
);
