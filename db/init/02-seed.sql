-- Демо-данные: три категории и 24 товара для стенда.

insert into categories (name) values
    ('Периферия'),
    ('Сетевое оборудование'),
    ('Расходники');

insert into products (name, category_id, price, stock) values
    -- Периферия
    ('Клавиатура USB', (select id from categories where name = 'Периферия'), 990.00, 15),
    ('Мышь оптическая USB', (select id from categories where name = 'Периферия'), 650.00, 24),
    ('Коврик для мыши', (select id from categories where name = 'Периферия'), 250.00, 0),
    ('Наушники с микрофоном', (select id from categories where name = 'Периферия'), 1890.00, 8),
    ('Веб-камера USB 1080p', (select id from categories where name = 'Периферия'), 3250.00, 5),
    ('Хаб USB на 4 порта', (select id from categories where name = 'Периферия'), 1150.00, 12),
    ('Кабель-удлинитель USB 1.8 м', (select id from categories where name = 'Периферия'), 320.00, 30),
    ('Монитор 24 дюйма', (select id from categories where name = 'Периферия'), 12900.00, 4),

    -- Сетевое оборудование
    ('Кабель UTP cat5e 305 м', (select id from categories where name = 'Сетевое оборудование'), 4750.00, 6),
    ('Кабель UTP cat6 305 м', (select id from categories where name = 'Сетевое оборудование'), 6200.00, 3),
    ('Коммутатор на 8 портов', (select id from categories where name = 'Сетевое оборудование'), 2990.00, 7),
    ('Маршрутизатор офисный', (select id from categories where name = 'Сетевое оборудование'), 4300.00, 5),
    ('Коннектор RJ-45, упаковка 100 шт.', (select id from categories where name = 'Сетевое оборудование'), 480.00, 20),
    ('Патч-панель на 24 порта', (select id from categories where name = 'Сетевое оборудование'), 3100.00, 2),
    ('Сетевая розетка одинарная', (select id from categories where name = 'Сетевое оборудование'), 290.00, 18),
    ('Инжектор PoE', (select id from categories where name = 'Сетевое оборудование'), 1690.00, 9),

    -- Расходники
    ('Картридж лазерный', (select id from categories where name = 'Расходники'), 2450.00, 11),
    ('Бумага А4, 500 листов', (select id from categories where name = 'Расходники'), 390.00, 40),
    ('Тонер-картридж универсальный', (select id from categories where name = 'Расходники'), 890.00, 14),
    ('Салфетки для очистки техники', (select id from categories where name = 'Расходники'), 150.00, 25),
    ('Изолента ПВХ', (select id from categories where name = 'Расходники'), 60.00, 50),
    ('Стяжки нейлоновые, упаковка 100 шт.', (select id from categories where name = 'Расходники'), 120.00, 35),
    ('Пробник бесплатный (образец)', (select id from categories where name = 'Расходники'), 0.00, 10),
    ('Термопаста', (select id from categories where name = 'Расходники'), 340.00, 7);
