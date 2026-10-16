// PIVXie's shield keys against MyPIVXWallet's: the values below come from
// the pivx-shield-rust 1.3.0 package MyPIVXWallet ships (its lockfile's
// sha512), called as pivx-shield 1.3.1's PIVXShield.create and
// getNewAddress do, for the phrase of pivx_accounts_test.dart.
//
// Run on the build VM:
//   PIVX_SHIELD_LIB=/root/work/pivxshield/rust/target/release/libpivx_shield_ffi.so \
//   flutter test test/pivx/pivx_shield_mpw_test.dart
import 'dart:io';

import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter_libpivxshield/flutter_libpivxshield.dart';
import 'package:flutter_test/flutter_test.dart';

const _mnemonic =
    "high fruit sick panther hospital place robust seminar maze benefit shoe bleak";

/// MyPIVXWallet's keys by passphrase, coin type and account, with its
/// first shield address: getNewAddress skips diversifier index 0, so it
/// isn't always the default address PIVXie starts with. Both belong to
/// the same key and see the same coins.
const _mpw = [
  (
    passphrase: "",
    coinType: 119,
    account: 0,
    extsk: "p-secret-spending-key-main1qwrul07cqqqqpqzdc9ylxaf5typgldt9tmcnp3nedx0t2mxwmw6vquwxf8zulsxqdd4q8vv29fqf69c3tastgctawd60m843wrjvjk24qr37cflt563s4cx227sws38mkk4w3272g0gy0wu8ku00krjlvyqf53d82nnxf0sxu3ucum3slflc0f7rrgt7lpdpvyc8umshl5lgj636qnu3ewy5zh7nc44g39udh2tmc0mzcdamrjn9kdnstycs875y862a6uyds29sk0g3l6hly",
    extfvk: "pxviews1qwrul07cqqqqpqzdc9ylxaf5typgldt9tmcnp3nedx0t2mxwmw6vquwxf8zulsxqddlhfd4kcp4pchnn98ehynvnltnc53avkt27arhjz4u66cwukg0c27q38d0yyj74fcmrtrmusj57j8a6qw8hvvlchlh9deyv9tmzeu5uu3ucum3slflc0f7rrgt7lpdpvyc8umshl5lgj636qnu3ewy5zh7nc44g39udh2tmc0mzcdamrjn9kdnstycs875y862a6uyds29sk0gy2hxhh",
    defaultAddress: "ps10jk9wduzjr8vv99amslge75w5z44j3p8t4pk0v2tjq5wp982lzddqe4gt89m5t9tuvkguhqwmjd",
    firstAddress: "ps10jk9wduzjr8vv99amslge75w5z44j3p8t4pk0v2tjq5wp982lzddqe4gt89m5t9tuvkguhqwmjd",
  ),
  (
    passphrase: "",
    coinType: 119,
    account: 1,
    extsk: "p-secret-spending-key-main1qwrul07cqyqqpqrkx0qernghjj4xg7rmmc7qk98dsl7eu84rrxduqwwr844hpp667tmjaepwqkvhllw844xgv89km7muu5w4w66ze8rhx0kuqqnmv29q4dtx7052esvdmsw50w380f4ng2anyu7zvjyhsg3vgckge7797jcprs64rua9eccfjagtkkve7af8wwla5p2dqgmxzxlppg8n0722n80xjv8g0ms5kj3jta2uvn8wez49y0y068tcr9da5lm7w24u50g9uhg7hdmq3",
    extfvk: "pxviews1qwrul07cqyqqpqrkx0qernghjj4xg7rmmc7qk98dsl7eu84rrxduqwwr844hpp667txn3g2u2xfgfl3j48gdva5z7fp38kuv8rgpxv0y98zfn5jvgd022h25jm805mr83lhxu6pe6a8scdxrhpfp0592nx5e773lcdqehf6mrs64rua9eccfjagtkkve7af8wwla5p2dqgmxzxlppg8n0722n80xjv8g0ms5kj3jta2uvn8wez49y0y068tcr9da5lm7w24u50g9uhgcwsx2d",
    defaultAddress: "ps1krykf4egdy46wtc9c07exhzdg226gytgyu49yus73kpy2g577w9pcku6gm39zyuurwydulecqyr",
    firstAddress: "ps1zt08zt9eussxzyjur6hz5lyqjmwte0px52ku88lzkkcdg7wk0fzxpx8njw0zj3u7atxpjn5ddgw",
  ),
  (
    passphrase: "",
    coinType: 119,
    account: 2,
    extsk: "p-secret-spending-key-main1qwrul07cqgqqpqqjqs0knmhfvp7mtl9kvtt78wphvx4zwnzysmqkl9zt39fnckd3ms5m82frveqz9z5ryq49uftg3dh9g8k5palmqzecv02d0hchkvmq2cndkdc4puzte4mp9reayq4r0zfd24erzdhaknvnyzvkj3sfxkcy27qkay9mektwvs8qf84na6zftf97unqzxka28g2hslw5vfzfa9gvk02vcj6nwegsaqtu9xtfmc7rnvhnc0s72cpq2s8ne9fcqmtl8vqt597q4",
    extfvk: "pxviews1qwrul07cqgqqpqqjqs0knmhfvp7mtl9kvtt78wphvx4zwnzysmqkl9zt39fnckd3mja0zhd8wz2wz7yz07xhtgve4la80u9asydac88a7d7suw0kdu2vc6n7jzkvfj9udjqas9y86mvkymtwzhaspks9nsmnm9nke5a9qess27qkay9mektwvs8qf84na6zftf97unqzxka28g2hslw5vfzfa9gvk02vcj6nwegsaqtu9xtfmc7rnvhnc0s72cpq2s8ne9fcqmtl8vquvkwcc",
    defaultAddress: "ps130pyv4wuvxq39c5lxrptdl5cnsvnhuvw05vacxw6hjytcf7zsnyjmk7je7s43w7mp09vc74h0rm",
    firstAddress: "ps130pyv4wuvxq39c5lxrptdl5cnsvnhuvw05vacxw6hjytcf7zsnyjmk7je7s43w7mp09vc74h0rm",
  ),
  (
    passphrase: "",
    coinType: 1,
    account: 0,
    extsk: "p-secret-spending-key-test1qdd2mlg6qqqqpqx7kkjh44zevq9cf3wg8923hjphgdpvwxz7kapdrj78r6dx6z570yze3djgcu36kkq3089nqv8jws99wem3z5pxwsyuas3hp3l02r0sqvt9355nnvzesh4v5qehgfmnfgd24yrdqy0j89k4kp3mjq23ywgpl2pwm6ygfeyf86cc47vcjms27s8uydycz0c0ccjqfd4mt494th2764hndw3wtljty4r9l5qufgh3z6pn67ft9m4lyydg9ma9d4u0q5g2dstpe",
    extfvk: "pxviewtestsapling1qdd2mlg6qqqqpqx7kkjh44zevq9cf3wg8923hjphgdpvwxz7kapdrj78r6dx6z5709htcm4wrmtjrygzr4x8fsfk9cg5vpjyju4d5yq4v8awjcar9uut38yprvcfleqwhp0lzfxeqcds4hrrywqhl4cdyxwagucv8w0tw72al2pwm6ygfeyf86cc47vcjms27s8uydycz0c0ccjqfd4mt494th2764hndw3wtljty4r9l5qufgh3z6pn67ft9m4lyydg9ma9d4u0q5gw6hdjx",
    defaultAddress: "ptestsapling1cf76nf7zvrpk6zct9eqtqdk4ftxamtq6mp6ymustt8x6tnzdjvecwj92vmtzj9363ermznc64xk",
    firstAddress: "ptestsapling1cun5wtuy52tdnc928wcx7mra3n2rq0ajc7xsnw8ze6pamfa92hy648xary3ckafk5ka7uxkhf7l",
  ),
  (
    passphrase: "",
    coinType: 1,
    account: 1,
    extsk: "p-secret-spending-key-test1qdd2mlg6qyqqpqxag3lafa28yv2gpwq6lytu89683fxwzacjg0g3gsc55pfn7sxnnq2jrlvexngaj4wgk9ej8ke3q4w7ulrm7c2p3mc482w5uprm0wdsmz3rdtn2zmt3xp77k9tlty9tuxht7kk2hcr7uxhzadjpfxv0r7gzqy4ncgdasj3xheqzy3vfnudf2jg2uh5mg66qvtleg3xjulsm5xqdwrzlm8f4nmjhvudrldh6dgwz9k8hcgdgl7j522j8c0vxf97qm8sfd3y9g",
    extfvk: "pxviewtestsapling1qdd2mlg6qyqqpqxag3lafa28yv2gpwq6lytu89683fxwzacjg0g3gsc55pfn7sxnnp78uertmm28clqrdcrwp9xcvujztf8qu7v2sv7fdtut3kcz0rx65wzaplptnagp7dupe7t008hasu87l4mrdw0t4657msvme6t62ccaqy4ncgdasj3xheqzy3vfnudf2jg2uh5mg66qvtleg3xjulsm5xqdwrzlm8f4nmjhvudrldh6dgwz9k8hcgdgl7j522j8c0vxf97qm8swcdsha",
    defaultAddress: "ptestsapling14yyhzc90gpcw4jfz7za27ngy5etchdc8md660xayk6n2p7dryn2nvy9fy25tt0c0k290qn5s03k",
    firstAddress: "ptestsapling1pcppvpfghzmmfnsd9en5tgypt9zegzt93m35sp2rlxgcu9qc742c5l90dmhralnywk5qqxzalk9",
  ),
  (
    passphrase: "",
    coinType: 1,
    account: 2,
    extsk: "p-secret-spending-key-test1qdd2mlg6qgqqpqzeev3f850fskcf6zpxvzqhjzm2c7k36cu5va2x8tntha9rv8f8guvmkf6qky3m67xpph83h8nqfz4uq5k5v9g02ncm7y26pc47unns2l6z3ujsn23wxzmnfgjupghyy7g84ex4yee8chscd9lx7a6jfycvkw75gs0lg0pwhc29tlf0pd4c9e7qgl2ppufy9hmlv27vyd8rgnhyzfp37rfd2zhuhq9sjwcp609zx2erqa384munzk2rh7cvhtm8clsupjg5j",
    extfvk: "pxviewtestsapling1qdd2mlg6qgqqpqzeev3f850fskcf6zpxvzqhjzm2c7k36cu5va2x8tntha9rv8f8gauj8e3yhz9nx79lx7wsze95rf4ux5dqjuer5sjksrmjaajrzqkqq03mf5v3rd9yyf38wfyayggrslmzxf5z85qzkrvrvs20r0pulsk0kw75gs0lg0pwhc29tlf0pd4c9e7qgl2ppufy9hmlv27vyd8rgnhyzfp37rfd2zhuhq9sjwcp609zx2erqa384munzk2rh7cvhtm8clscuwhje",
    defaultAddress: "ptestsapling17wpzsxcupsadjhnc8kxvddk26ujswdyum0w3kqt2p58cpvnxxa8hpns7w6rstmjzwm52kk22nlj",
    firstAddress: "ptestsapling1scayuhhd7eqqw8aywj8lkauj8mfp9ygw45h4qr7zqs4azhftll9v69llclr78j4ksujkxpqhusf",
  ),
  (
    passphrase: "123456",
    coinType: 119,
    account: 0,
    extsk: "p-secret-spending-key-main1qv0d6yp2qqqqpqr0d3vd2k6pp9gsuuzwza3n9cwcfdm607k0f5qep0al34kwsu2wv9ph9230wjgwgdnpj6he65k3n6wrm58hq2nv7pe2tjvz3njnj92sejpjag38j8zztlse0ps7azdjup56klv6a90rkajlafesmzpewvqx6f7jqkt2nmz0exnfl573t4jc7mmdnpu29xtunhd3jwrn42a5rde3vanz9000ngxgk05dfxmf6zzmttpg8g7huhllgsyv269nphht7gcx93z98",
    extfvk: "pxviews1qv0d6yp2qqqqpqr0d3vd2k6pp9gsuuzwza3n9cwcfdm607k0f5qep0al34kwsu2wv9fxf38c89e2ls3enexj0t9g4w3mxpzuj34a5vehzn00z9qg52ql8cu2praestnnh25azmjp5lcd3emzt2p2kzgqgg888fgqz6c0wej96f7jqkt2nmz0exnfl573t4jc7mmdnpu29xtunhd3jwrn42a5rde3vanz9000ngxgk05dfxmf6zzmttpg8g7huhllgsyv269nphht7gcrgtyjq",
    defaultAddress: "ps1evsulds8s3c7ken05uku0lxqtgk780pp0mhq5mv58uc9wuw8cxt0tmupvaczwz5m0h92jlvhzg2",
    firstAddress: "ps1evsulds8s3c7ken05uku0lxqtgk780pp0mhq5mv58uc9wuw8cxt0tmupvaczwz5m0h92jlvhzg2",
  ),
  (
    passphrase: "123456",
    coinType: 119,
    account: 1,
    extsk: "p-secret-spending-key-main1qv0d6yp2qyqqpqyy8l8lwhmgssxsmayjkgm33gg5y0cfz5pqhkgfqpuhkmagra6d4n3j55k6623gfr7henp460nzxg6edmp25e9ztxvppl4s3u8mfvlq3hc3gjv2tdjy2h2rw8xrexy2lm06y4qt5ewxwegepu6vpdu6axqqha8cczyz5sj9td36h9hry9ptgk8ksgvm2jrwruuj2l4kvkm8mn6nskc5tpms56hl7as3dhmgdsvhgjz30yuckhuz2k74lglg7e7fmsqhq6y09",
    extfvk: "pxviews1qv0d6yp2qyqqpqyy8l8lwhmgssxsmayjkgm33gg5y0cfz5pqhkgfqpuhkmagra6d4jpths97jrsrlspuyp6dm6ex53gnes7hd7u07el78ngpytj6hxc6efygfkxgddas7ly3haztnnuj9smr4qg7lqusvmpqa2wz4225fz64ha8cczyz5sj9td36h9hry9ptgk8ksgvm2jrwruuj2l4kvkm8mn6nskc5tpms56hl7as3dhmgdsvhgjz30yuckhuz2k74lglg7e7fmsqm34lk7",
    defaultAddress: "ps19ms50htdscjpm62t3wps6hkmrwzmqh6vj7z80kcyr0cy9ndjfcrhxxsgpykkkawpxca2jwe0fvx",
    firstAddress: "ps19ms50htdscjpm62t3wps6hkmrwzmqh6vj7z80kcyr0cy9ndjfcrhxxsgpykkkawpxca2jwe0fvx",
  ),
  (
    passphrase: "123456",
    coinType: 119,
    account: 2,
    extsk: "p-secret-spending-key-main1qv0d6yp2qgqqpqzguv7dc9kq4uj8yyq48sw6kg3qjxumweyqttyhkv4sr3a4jgqdthsjmav5gclg0crt3xemngu43w6n3uqgava4y7e7shsrxmd9439qec6538sjrhvltk93y500agtlfwv8l8e6ucrx3qtnt8kjjzup39czr7m83l0u7hxfmukj6eetzhewwsvv9m77m2k668up94dayqwd49mx5e44h9u8z6zmaz24k9d3js5mmz8jr6ayk8f9dv8z6n27lf7gn8g5kv3gg",
    extfvk: "pxviews1qv0d6yp2qgqqpqzguv7dc9kq4uj8yyq48sw6kg3qjxumweyqttyhkv4sr3a4jgqdt42cdp7cpsts8zrg79u4g0x7kd0gs5ts54nkpg8vqlyvu7aq7w4u7f4msc6prky7qc7x0wxz2h660qplnt88akfyjexqarc7n4v46fe7r7m83l0u7hxfmukj6eetzhewwsvv9m77m2k668up94dayqwd49mx5e44h9u8z6zmaz24k9d3js5mmz8jr6ayk8f9dv8z6n27lf7gn8g8dy2us",
    defaultAddress: "ps1gcxamysxsfw6zl22ucruawhr0lul3zhpr5ux9hwmpp5w85yekrzlxxprk2fsjj5hs8g765lkh4u",
    firstAddress: "ps13juvn4n0pzl0e3f8v64rmlfgjtfddwf9gk0hjn9a3glfwvlt4pfxxjadn578shvald8ecsk4r2v",
  ),
  (
    passphrase: "123456",
    coinType: 1,
    account: 0,
    extsk: "p-secret-spending-key-test1qdezmm50qqqqpq8343rmxhatkd43d9yv2efs5tkxxx46h3v9ewycprva7fk95ra4ek5ymcwu5f6wtcqeq8hx9xnfsjvrxdqyxw7lshw3vkttgt9g6raqw9v6q6yg7aampz5y0xcukgj46pta660luyy92g3quyjp2cwat2cxk9emtts075u4mel9al8j3t5zn8p7f38p0z5przaw268swuwr45et6s455tr483xmg0yleuwpkhvv8wlutmz3l7cq6837ve9874u637sh9d5jz",
    extfvk: "pxviewtestsapling1qdezmm50qqqqpq8343rmxhatkd43d9yv2efs5tkxxx46h3v9ewycprva7fk95ra4eh24aemylr8svuc63gzjjm5664yp232q5m8vuguwz7spk2j3klv36r4m8q24k774xv2q49uc2rnk3jx2djjrj9kt8z3a77xf5jfs85zyk9emtts075u4mel9al8j3t5zn8p7f38p0z5przaw268swuwr45et6s455tr483xmg0yleuwpkhvv8wlutmz3l7cq6837ve9874u637s32jqsm",
    defaultAddress: "ptestsapling1m9ep45ttc4qdtdtn8h8xf6mxdjyz4fpduzvmah70xnq4c7rl4av6tdd8u94h046c379xzm2m4c3",
    firstAddress: "ptestsapling1eflqjhe24azp6qmt90wehlas0v77qu874qyzpmycn4fxyrelgf4agcdxn9jys3c6fhknw98kx27",
  ),
  (
    passphrase: "123456",
    coinType: 1,
    account: 1,
    extsk: "p-secret-spending-key-test1qdezmm50qyqqpqquwf4jlg9y6h5h8z858hljrnkmsmn8dy8mpncjuuxzz30sufxrx9zfsvpmxl8q60umlu8v4an4pmyy5u7nmm2wf57d06t4jjk5afqsekcsey7m23vl3y37w8dvrf24ydymmcn2m9l3frmll9wh44wn24qxwrqk7ve2spzpdjzxldqgetf29d8xfx8wq747rm2tst78wagq9azyqxaa72v6nne0sjypqjvkdfejyyn3jq4yu8qua9src2thqjtx6cglcxexm",
    extfvk: "pxviewtestsapling1qdezmm50qyqqpqquwf4jlg9y6h5h8z858hljrnkmsmn8dy8mpncjuuxzz30sufxrx92yxz7g33g6pqyfz45ckpu9nrkdzq0d5hjlrfwpm9gxyqk43sx2uavzn3ccgcuyrugwauln9rwvcpc4phyhyxk9rn85jhcnn99ll7h9wrqk7ve2spzpdjzxldqgetf29d8xfx8wq747rm2tst78wagq9azyqxaa72v6nne0sjypqjvkdfejyyn3jq4yu8qua9src2thqjtx6cgy0t0s5",
    defaultAddress: "ptestsapling14whp7npunk4y3zxm40l9ykp0eyhs03sv4ae64u7qj0v928syxespaar94agsn3uqlxruya7qmen",
    firstAddress: "ptestsapling14whp7npunk4y3zxm40l9ykp0eyhs03sv4ae64u7qj0v928syxespaar94agsn3uqlxruya7qmen",
  ),
  (
    passphrase: "123456",
    coinType: 1,
    account: 2,
    extsk: "p-secret-spending-key-test1qdezmm50qgqqpq948vn8w8tx626q5kgf3mq3kfzzw04hm5dl70ydszu9z9p6majvn57y9npdy8etrj0dqu73zs9casduyn4w6pehta2jephytpskq3pqg5kp38lnxvnwt0jcukzp9er2fmctux7ms7c0qwuraja4d5swcqggaw6yeu40905valg9g8g4jlkyc44u88vfmxw4z7zhurgx7vpafzm2xxuqcu8rxg8n7a88caghw79zcfa9y64rsusaam5zjhu0zk433uccpcp0l",
    extfvk: "pxviewtestsapling1qdezmm50qgqqpq948vn8w8tx626q5kgf3mq3kfzzw04hm5dl70ydszu9z9p6majvnhwr06tz028scmamuapv40hw88ytcc0t4vcqwh2uw35qgrzcefcdprzq5lzvf04dhu3jtftuexwwpc472qgywphlkg2atxfgjj848n5daw6yeu40905valg9g8g4jlkyc44u88vfmxw4z7zhurgx7vpafzm2xxuqcu8rxg8n7a88caghw79zcfa9y64rsusaam5zjhu0zk433ucm7hmmk",
    defaultAddress: "ptestsapling1haveqasnescm4p4dc88qvc5qy3lel7uapqyezva3jfl3jph0ca9yz2dt5mgd0me2kye32uj3xuy",
    firstAddress: "ptestsapling1haveqasnescm4p4dc88qvc5qy3lel7uapqyezva3jfl3jph0ca9yz2dt5mgd0me2kye32uj3xuy",
  ),
];

void main() {
  final skip = Platform.environment["PIVX_SHIELD_LIB"] == null
      ? "PIVX_SHIELD_LIB not set"
      : null;

  for (final v in _mpw) {
    final isTestnet = v.coinType == 1;
    test("account ${v.account} has MyPIVXWallet's shield key on "
        "${isTestnet ? "testnet" : "mainnet"}"
        "${v.passphrase.isEmpty ? "" : " with a passphrase"}", () {
      // As PivxWallet._extskFromSeed and _extfvk.
      final seed = bip39.mnemonicToSeed(_mnemonic, passphrase: v.passphrase);
      final extsk = PivxShield.extendedSpendingKey(
        seed: seed.sublist(0, 32),
        coinType: v.coinType,
        accountIndex: v.account,
      );
      expect(extsk, v.extsk);
      final extfvk = PivxShield.extendedFullViewingKey(
        extsk: extsk,
        isTestnet: isTestnet,
      );
      expect(extfvk, v.extfvk);
      expect(
        PivxShield.defaultAddress(extfvk: extfvk, isTestnet: isTestnet).address,
        v.defaultAddress,
      );
      expect(
        PivxShield.nextAddress(
          extfvk: extfvk,
          diversifierIndex: List.filled(11, 0),
          isTestnet: isTestnet,
        ).address,
        v.firstAddress,
      );
    }, skip: skip);
  }
}
