BEGIN;

INSERT INTO public.avatar_catalog (
    id,
    display_name,
    storage_path,
    category,
    sort_order,
    is_active,
    created_at,
    bg_color
)
VALUES
    ('avatar_aang', 'Aang', 'avatar_aang_1772809370453.png', 'animation', 1, true, '2026-03-06 17:21:42.178516+00', '#0060F8'),
    ('avatar_katara', 'Katara', 'avatar_katara_1772809386366.png', 'animation', 18, true, '2026-03-06 17:21:56.83401+00', '#00A0A8'),
    ('avatar_ash', 'Ash', 'avatar_ash_1772809405294.png', 'anime', 3, true, '2026-03-06 17:21:43.936166+00', '#E00808'),
    ('avatar_chihiro', 'Chihiro', 'avatar_chihiro_1772809422792.png', 'anime', 4, true, '2026-03-06 17:21:45.453843+00', '#88E070'),
    ('avatar_eren', 'Eren', 'avatar_eren_1772808836514.png', 'anime', 8, true, '2026-03-06 17:21:49.672554+00', '#900018'),
    ('avatar_gojo', 'Gojo', 'avatar_gojo_1772826847969.png', 'anime', 11, true, '2026-03-06 20:13:40.289445+00', '#00F8F8'),
    ('avatar_goku', 'Goku', 'avatar_goku_1772786622108.png', 'anime', 12, true, '2026-03-06 17:21:51.384091+00', '#F84000'),
    ('avatar_jinwoo', 'Jinwoo', 'avatar_jinwoo_1772808878532.png', 'anime', 15, true, '2026-03-06 17:21:54.876849+00', '#0058F8'),
    ('avatar_killua', 'Killua', 'avatar_killua_1772826924033.png', 'anime', 19, true, '2026-03-06 20:13:49.229024+00', '#0030F8'),
    ('avatar_levi', 'Levi', 'avatar_levi_1772826833149.png', 'anime', 23, true, '2026-03-06 20:13:53.351561+00', '#484848'),
    ('avatar_mikasa', 'Mikasa', 'avatar_mikasa_1772808997012.png', 'anime', 24, true, '2026-03-06 17:21:58.685948+00', '#007870'),
    ('avatar_naruto', 'Naruto', 'avatar_naruto_1772786640402.png', 'anime', 25, true, '2026-03-06 17:22:00.057474+00', '#D8F800'),
    ('avatar_saitama', 'Saitama', 'avatar_saitama_1772826938248.png', 'anime', 29, true, '2026-03-06 20:14:00.440202+00', '#F8D000'),
    ('avatar_arthur_morgan', 'Arthur Morgan', 'avatar_arthur_morgan_1772786328141.png', 'gaming', 2, true, '2026-03-06 17:21:43.069595+00', '#B01028'),
    ('avatar_geralt', 'Geralt', 'avatar_geralt_1772826884310.png', 'gaming', 10, true, '2026-03-06 20:08:26.948055+00', '#380070'),
    ('avatar_kratos', 'Kratos', 'avatar_kratos_1772826869090.png', 'gaming', 20, true, '2026-03-06 20:08:35.849845+00', '#880000'),
    ('avatar_lara', 'Lara', 'avatar_lara_1772826963671.png', 'gaming', 22, true, '2026-03-06 20:13:52.351944+00', '#008878'),
    ('avatar_v', 'V', 'avatar_v_1772827227584.png', 'gaming', 32, true, '2026-03-06 20:08:44.490983+00', '#000830'),
    ('avatar_linear_woman_teal', 'Lin', 'avatar_linear_teal_v3.png', 'linear', 35, true, '2026-03-24 05:39:36.371988+00', '#008080'),
    ('avatar_linear_man_purple', 'Max', 'avatar_linear_purple_v3.png', 'linear', 36, true, '2026-03-24 05:39:36.952927+00', '#6B21A8'),
    ('avatar_linear_woman_red', 'Ava', 'avatar_linear_red_v3.png', 'linear', 37, true, '2026-03-24 05:39:37.69426+00', '#E11D48'),
    ('avatar_linear_man_navy', 'Theo', 'avatar_linear_navy_v3.png', 'linear', 38, true, '2026-03-24 05:39:38.258116+00', '#1E3A5F'),
    ('avatar_linear_woman_yellow', 'Zara', 'avatar_linear_yellow_v3.png', 'linear', 39, true, '2026-03-24 05:39:38.792255+00', '#D97706'),
    ('avatar_linear_man_green', 'Kai', 'avatar_linear_green_v3.png', 'linear', 40, true, '2026-03-24 05:39:39.368491+00', '#065F46'),
    ('avatar_linear_woman_pink', 'Nova', 'avatar_linear_pink_v3.png', 'linear', 41, true, '2026-03-24 05:39:39.932199+00', '#BE185D'),
    ('avatar_furiosa', 'Furiosa', 'avatar_furiosa_1772827439561.png', 'movie', 9, true, '2026-03-06 20:08:25.760928+00', '#D08848'),
    ('avatar_harry_potter', 'Harry Potter', 'avatar_harry_potter_1772786358133.png', 'movie', 13, true, '2026-03-06 17:21:52.391484+00', '#F8B000'),
    ('avatar_jack_sparrow', 'Jack Sparrow', 'avatar_jack_sparrow_1772786396797.png', 'movie', 14, true, '2026-03-06 17:21:53.839715+00', '#F8F8F8'),
    ('avatar_neo', 'Neo', 'avatar_neo_1772786377143.png', 'movie', 27, true, '2026-03-06 17:22:02.031355+00', '#88F800'),
    ('avatar_daenerys', 'Daenerys', 'avatar_daenerys_1772786201651.png', 'tv', 5, true, '2026-03-06 17:21:46.565341+00', '#00B8D8'),
    ('avatar_dexter', 'Dexter', 'avatar_dexter_1772808898372.png', 'tv', 6, true, '2026-03-06 17:21:47.589616+00', '#A80808'),
    ('avatar_eleven', 'Eleven', 'avatar_eleven_1772785893766.png', 'tv', 7, true, '2026-03-06 17:21:48.754052+00', '#8800F8'),
    ('avatar_joel', 'Joel', 'avatar_joel_1772827212455.png', 'tv', 16, true, '2026-03-06 20:08:32.422169+00', '#102010'),
    ('avatar_jon_snow', 'Jon Snow', 'avatar_jon_snow_1772786050374.png', 'tv', 17, true, '2026-03-06 17:21:55.915187+00', '#004090'),
    ('avatar_lalo', 'Lalo', 'avatar_lalo_1772808914536.png', 'tv', 21, true, '2026-03-06 17:21:57.834999+00', '#E09018'),
    ('avatar_negan', 'Negan', 'avatar_negan_1772808934794.png', 'tv', 26, true, '2026-03-06 17:22:01.01784+00', '#780078'),
    ('avatar_rick_grimes', 'Rick Grimes', 'avatar_rick_grimes_1772786275264.png', 'tv', 28, true, '2026-03-06 17:22:02.997203+00', '#C85018'),
    ('avatar_saul_goodman', 'Saul Goodman', 'avatar_saul_goodman_1772786019049.png', 'tv', 30, true, '2026-03-06 17:22:03.872131+00', '#F84000'),
    ('avatar_tommy_shelby', 'Tommy Shelby', 'avatar_tommy_shelby_1772786000275.png', 'tv', 31, true, '2026-03-06 17:22:04.797558+00', '#F83040'),
    ('avatar_walter_white', 'Walter White', 'avatar_walter_white_1772785927308.png', 'tv', 33, true, '2026-03-06 17:22:06.346653+00', '#F8C000'),
    ('avatar_wednesday', 'Wednesday', 'avatar_wednesday_1772786225606.png', 'tv', 34, true, '2026-03-06 17:22:07.609503+00', '#500840')
ON CONFLICT (id) DO UPDATE
SET display_name = excluded.display_name,
    storage_path = excluded.storage_path,
    category = excluded.category,
    sort_order = excluded.sort_order,
    is_active = excluded.is_active,
    bg_color = excluded.bg_color;

INSERT INTO nuvio_migrations.schema_migrations (version)
VALUES ('00000000000005')
ON CONFLICT (version) DO NOTHING;

COMMIT;
