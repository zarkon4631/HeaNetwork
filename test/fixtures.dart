import 'dart:convert';

const uuid = '775ddd8e-a994-4511-b059-e132efe15735';
const realityPbk = '_xA8ToQ1b4H3edrRLKfgas02Sf49OTHr2hy1pUCO9GY';
const wgPrivate = 'UKtORsrJXa7pb4Ozsj44l/O5jXeEWl3qaIgc47LTe28=';
const wgPublic = 'nWexrSSXL11fSCD86V0rZwGLEt7nKjdEIfbkh9x6kBI=';

String _b64(String s) => base64.encode(utf8.encode(s));

final xhttpExtra = Uri.encodeComponent(jsonEncode({
  'xPaddingBytes': '100-1000',
  'noGRPCHeader': true,
  'scMaxEachPostBytes': 1000000,
  'xmux': {'maxConcurrency': '16-32', 'hMaxRequestTimes': '600-900'},
  'headers': {'X-Test': '1'},
}));

/// Share links in the shapes a 3x-ui panel (and common clients) emit.
final sampleLinks = <String, String>{
  'vless-reality-vision':
      'vless://$uuid@203.0.113.10:443?type=tcp&security=reality&pbk=$realityPbk'
          '&fp=chrome&sni=www.microsoft.com&sid=0123abcd&spx=%2F'
          '&flow=xtls-rprx-vision#VLESS%20Reality',
  'vless-ws-tls':
      'vless://$uuid@example.com:443?type=ws&security=tls&path=%2Fws%3Fed%3D2048'
          '&host=cdn.example.com&sni=example.com&fp=firefox&alpn=http%2F1.1#ws',
  'vless-grpc-reality':
      'vless://$uuid@203.0.113.10:8443?type=grpc&serviceName=grpc-svc'
          '&security=reality&pbk=$realityPbk&sid=ab&sni=yahoo.com&fp=chrome#grpc',
  'vless-xhttp-reality':
      'vless://$uuid@203.0.113.10:443?type=xhttp&path=%2Fx&host=example.com'
          '&mode=packet-up&security=reality&pbk=$realityPbk&sid=0123abcd'
          '&sni=example.com&fp=chrome&extra=$xhttpExtra#xhttp-reality',
  'vless-xhttp-tls':
      'vless://$uuid@example.com:443?type=xhttp&path=%2Fx&security=tls'
          '&sni=example.com&mode=auto#xhttp-tls',
  'vless-httpupgrade':
      'vless://$uuid@example.com:443?type=httpupgrade&path=%2Fup'
          '&host=example.com&security=tls&sni=example.com#hu',
  'vless-mkcp':
      'vless://$uuid@203.0.113.10:20000?type=kcp&headerType=wechat-video'
          '&seed=secret&security=none#kcp',
  'vless-tcp-http':
      'vless://$uuid@203.0.113.10:80?type=tcp&headerType=http&host=a.com'
          '&path=%2F&security=none#tcp-http',
  'vless-ipv6':
      'vless://$uuid@[2001:db8::1]:443?type=tcp&security=tls&sni=example.com#v6',
  'vmess-ws-tls': 'vmess://${_b64(jsonEncode({
        'v': '2',
        'ps': 'VMess WS',
        'add': 'example.com',
        'port': '443',
        'id': uuid,
        'aid': '0',
        'scy': 'auto',
        'net': 'ws',
        'type': 'none',
        'host': 'example.com',
        'path': '/vm',
        'tls': 'tls',
        'sni': 'example.com',
        'fp': 'chrome',
      }))}',
  'vmess-tcp': 'vmess://${_b64(jsonEncode({
        'v': '2',
        'ps': 'VMess TCP',
        'add': '203.0.113.10',
        'port': 10086,
        'id': uuid,
        'aid': 0,
        'net': 'tcp',
        'type': 'none',
        'tls': '',
      }))}',
  'trojan-tls':
      'trojan://p%40ss%3Aword@example.com:443?security=tls&sni=example.com'
          '&type=tcp#Trojan',
  'trojan-ws':
      'trojan://password@example.com:443?type=ws&path=%2Ftr&host=example.com'
          '&security=tls&sni=example.com#Trojan-WS',
  'trojan-default-tls': 'trojan://password@example.com:443#Trojan-bare',
  'ss-sip002':
      'ss://${_b64('aes-256-gcm:pass:with:colons')}@203.0.113.10:8388#SS',
  'ss-2022':
      'ss://2022-blake3-aes-128-gcm:8JCsPssfgS8tiRwiMlhARg%3D%3D%3AVpKABcOpNP3ZrvdMS6nfhw%3D%3D'
          '@203.0.113.10:8388#SS2022',
  'ss-legacy':
      'ss://${_b64('chacha20-ietf-poly1305:secret@203.0.113.10:8389')}#SS-legacy',
  'hysteria2':
      'hysteria2://hy2-pass@example.com:443,20000-30000?sni=example.com'
          '&insecure=1&obfs=salamander&obfs-password=obfs-pass#HY2',
  'hy2-short': 'hy2://user:pass@203.0.113.10:8443?sni=example.com#HY2-short',
  'hysteria':
      'hysteria://example.com:36712?protocol=udp&auth=token&peer=example.com'
          '&insecure=1&upmbps=50&downmbps=200&alpn=hysteria&obfs=xplus'
          '&obfsParam=obfs#HY1',
  'tuic':
      'tuic://$uuid:tuic-pass@example.com:443?congestion_control=bbr'
          '&udp_relay_mode=native&alpn=h3&sni=example.com&allow_insecure=1#TUIC',
  'socks': 'socks://${_b64('user:pass')}@203.0.113.10:1080#SOCKS',
  'socks5-plain': 'socks5://203.0.113.10:1080#SOCKS-open',
  'wireguard-link':
      'wireguard://${Uri.encodeComponent(wgPrivate)}@203.0.113.10:51820'
          '?publickey=${Uri.encodeComponent(wgPublic)}'
          '&address=10.0.0.2%2F32&mtu=1380&keepalive=25#WG-link',
};

const wireGuardConf = '''
[Interface]
PrivateKey = $wgPrivate
Address = 10.8.0.2/24, fd00::2
DNS = 1.1.1.1
MTU = 1420

[Peer]
PublicKey = $wgPublic
PresharedKey = $wgPrivate
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = vpn.example.com:51820
PersistentKeepalive = 25
''';

const amneziaConf = '''
[Interface]
PrivateKey = $wgPrivate
Address = 10.8.1.2/32
DNS = 1.1.1.1, 1.0.0.1
Jc = 4
Jmin = 40
Jmax = 70
S1 = 86
S2 = 122
H1 = 1033089720
H2 = 1336452505
H3 = 1858775673
H4 = 332219739

[Peer]
PublicKey = $wgPublic
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 203.0.113.10:41234
PersistentKeepalive = 25
''';

/// AmneziaWG 2.0: header ranges, extra padding and a signature packet.
const amnezia2Conf = '''
[Interface]
PrivateKey = $wgPrivate
Address = 10.8.1.3/32
Jc = 5
Jmin = 10
Jmax = 50
S1 = 20
S2 = 30
S3 = 15
S4 = 8
H1 = 100000-200000
H2 = 300000-400000
H3 = 500000-600000
H4 = 700000-800000
I1 = <b 0xc70000000108>

[Peer]
PublicKey = $wgPublic
AllowedIPs = 0.0.0.0/0
Endpoint = [2001:db8::5]:41235
''';
