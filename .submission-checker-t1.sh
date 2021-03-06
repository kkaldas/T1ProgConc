#!/bin/bash
# Usage: grade dir_or_archive [output]

# Ensure realpath 
realpath . &>/dev/null
HAD_REALPATH=$(test "$?" -eq 127 && echo no || echo yes)
if [ "$HAD_REALPATH" = "no" ]; then
  cat > /tmp/realpath-grade.c <<EOF
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char** argv) {
  char* path = argv[1];
  char result[8192];
  memset(result, 0, 8192);

  if (argc == 1) {
      printf("Usage: %s path\n", argv[0]);
      return 2;
  }
  
  if (realpath(path, result)) {
    printf("%s\n", result);
    return 0;
  } else {
    printf("%s\n", argv[1]);
    return 1;
  }
}
EOF
  cc -o /tmp/realpath-grade /tmp/realpath-grade.c
  function realpath () {
    /tmp/realpath-grade $@
  }
fi

INFILE=$1
if [ -z "$INFILE" ]; then
  CWD_KBS=$(du -d 0 . | cut -f 1)
  if [ -n "$CWD_KBS" -a "$CWD_KBS" -gt 20000 ]; then
    echo "Chamado sem argumentos."\
         "Supus que \".\" deve ser avaliado, mas esse diretório é muito grande!"\
         "Se realmente deseja avaliar \".\", execute $0 ."
    exit 1
  fi
fi
test -z "$INFILE" && INFILE="."
INFILE=$(realpath "$INFILE")
# grades.csv is optional
OUTPUT=""
test -z "$2" || OUTPUT=$(realpath "$2")
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
# Absolute path to this script
THEPACK="${DIR}/$(basename "${BASH_SOURCE[0]}")"
STARTDIR=$(pwd)

# Split basename and extension
BASE=$(basename "$INFILE")
EXT=""
if [ ! -d "$INFILE" ]; then
  BASE=$(echo $(basename "$INFILE") | sed -E 's/^(.*)(\.(c|zip|(tar\.)?(gz|bz2|xz)))$/\1/g')
  EXT=$(echo  $(basename "$INFILE") | sed -E 's/^(.*)(\.(c|zip|(tar\.)?(gz|bz2|xz)))$/\2/g')
fi

# Setup working dir
rm -fr "/tmp/$BASE-test" || true
mkdir "/tmp/$BASE-test" || ( echo "Could not mkdir /tmp/$BASE-test"; exit 1 )
UNPACK_ROOT="/tmp/$BASE-test"
cd "$UNPACK_ROOT"

function cleanup () {
  test -n "$1" && echo "$1"
  cd "$STARTDIR"
  rm -fr "/tmp/$BASE-test"
  test "$HAD_REALPATH" = "yes" || rm /tmp/realpath-grade* &>/dev/null
  return 1 # helps with precedence
}

# Avoid messing up with the running user's home directory
# Not entirely safe, running as another user is recommended
export HOME=.

# Check if file is a tar archive
ISTAR=no
if [ ! -d "$INFILE" ]; then
  ISTAR=$( (tar tf "$INFILE" &> /dev/null && echo yes) || echo no )
fi

# Unpack the submission (or copy the dir)
if [ -d "$INFILE" ]; then
  cp -r "$INFILE" . || cleanup || exit 1 
elif [ "$EXT" = ".c" ]; then
  echo "Corrigindo um único arquivo .c. O recomendado é corrigir uma pasta ou  arquivo .tar.{gz,bz2,xz}, zip, como enviado ao moodle"
  mkdir c-files || cleanup || exit 1
  cp "$INFILE" c-files/ ||  cleanup || exit 1
elif [ "$EXT" = ".zip" ]; then
  unzip "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".tar.gz" ]; then
  tar zxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".tar.bz2" ]; then
  tar jxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".tar.xz" ]; then
  tar Jxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".gz" -a "$ISTAR" = "yes" ]; then
  tar zxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".gz" -a "$ISTAR" = "no" ]; then
  gzip -cdk "$INFILE" > "$BASE" || cleanup || exit 1
elif [ "$EXT" = ".bz2" -a "$ISTAR" = "yes"  ]; then
  tar jxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".bz2" -a "$ISTAR" = "no" ]; then
  bzip2 -cdk "$INFILE" > "$BASE" || cleanup || exit 1
elif [ "$EXT" = ".xz" -a "$ISTAR" = "yes"  ]; then
  tar Jxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".xz" -a "$ISTAR" = "no" ]; then
  xz -cdk "$INFILE" > "$BASE" || cleanup || exit 1
else
  echo "Unknown extension $EXT"; cleanup; exit 1
fi

# There must be exactly one top-level dir inside the submission
# As a fallback, if there is no directory, will work directly on 
# tmp/$BASE-test, but in this case there must be files! 
function get-legit-dirs  {
  find . -mindepth 1 -maxdepth 1 -type d | grep -vE '^\./__MACOS' | grep -vE '^\./\.'
}
NDIRS=$(get-legit-dirs | wc -l)
test "$NDIRS" -lt 2 || \
  cleanup "Malformed archive! Expected exactly one directory, found $NDIRS" || exit 1
test  "$NDIRS" -eq  1 -o  "$(find . -mindepth 1 -maxdepth 1 -type f | wc -l)" -gt 0  || \
  cleanup "Empty archive!" || exit 1
if [ "$NDIRS" -eq 1 ]; then #only cd if there is a dir
  cd "$(get-legit-dirs)"
fi

# Unpack the testbench
tail -n +$(($(grep -ahn  '^__TESTBENCH_MARKER__' "$THEPACK" | cut -f1 -d:) +1)) "$THEPACK" | tar zx
cd testbench || cleanup || exit 1

# Deploy additional binaries so that validate.sh can use them
test "$HAD_REALPATH" = "yes" || cp /tmp/realpath-grade "tools/realpath"
export PATH="$PATH:$(realpath "tools")"

# Run validate
(./validate.sh 2>&1 | tee validate.log) || cleanup || exit 1

# Write output file
if [ -n "$OUTPUT" ]; then
  #write grade
  echo "@@@###grade:" > result
  cat grade >> result || cleanup || exit 1
  #write feedback, falling back to validate.log
  echo "@@@###feedback:" >> result
  (test -f feedback && cat feedback >> result) || \
    (test -f validate.log && cat validate.log >> result) || \
    cleanup "No feedback file!" || exit 1
  #Copy result to output
  test ! -d "$OUTPUT" || cleanup "$OUTPUT is a directory!" || exit 1
  rm -f "$OUTPUT"
  cp result "$OUTPUT"
fi

echo -e "Grade for $BASE$EXT: $(cat grade)"

cleanup || true

exit 0

__TESTBENCH_MARKER__
� ���[ �=�V�H����h�X�6�d��a�3��@vro��#�6�Ɩ���f��u�S��nUH�R��@8gw�9	vwuuuuuUuu��0:���b��7{:���Ŀ����|u766���>__�>�t�7^l>"�ߎ�䙇��șЏn�WV�/�D��G�?	��,>���/Oz��gD�W��]e���Ez�77��H��H�����xi����Μ��j��ܭ�Nw���ݣׇ�����>8:�������`�����o����i{��,K��?H�6��k�|2��������r#�'���##�FH8�tF�Y��u�6|z�v����P���c����� ^����ï����S�ϣ���7���qC2���?�O�>�C3#�l���ɥD��&���SN�p�D������~p�e����6IX��|t#��1���KH�tjr����lOipN�������>���?�xX����������>z}�j@J��^����?� �pu�>��^�a�z��9��#��	��@�*�|4cJGg��C&���_���9�[d�é�}D,:b_�'����Y��� r}�{k�yz����(��WϽ!kvN����"�E�a�/ �����C����8@���l�?����Ǐ��[u�:.�!��.i����uF�m��HT���4o@�y�?8�c]D�;A���FC®v-Kv�%��o�on��g 	`=�|�J:����5oK(q�IH��(���U�u�L���~�u�߭޼:�wcT_��.T:�2>Xk���ҠֳP*���Ӄ� ��Y>�b�WO}٭[u�Vǫ!����1F����$Ј���Q�*WV�H��8�cXf��� �r��{6!��,p�hL�՟<]�����n�UZ_���GI'�����H䓡?�ENC�K]@�U��0�a�!�2 ����p���Ngm��;�N�5EQ��k�?Ǔ��Kg⎜��q�Ӌ;����g�����y����P�`���y쎽���������ѱ}:89�ip�����m�C��7������9h���h��O/��2t��<�]���љ�zn� �
hx�M��ի]��HAm�j+�R������u6�`Z�1��g`�� 3�M��ߘ������!�F�^��@�|�l=�z�0�gWN4��Q#���s4Y�*��?k��#����0�0���_k�
@s�A���>��x'}����/��g��ك���GSݮ�kn'i�e�&`c�.MܳL����4<������M����E�fM�P\_�3��3{�D=V����I,�����A3���֮W�ֵe�^��U���Ht{�Ϩ�#@�9S�Ҩ��`w8�����3���UCE�T̂}C�	��[-����٧`m#�ʉ8T}��-���6�@e�},�Mq��q�6lh��OF�l���1i,aS�J�j?h��u�V����lW�w#�����TǲE�n+������	q�#��`�����4-E2�]��R������Tl���.�e	����~b�^J[0 k����~�9Eb!���Ɗ�S.��`1����]喔�k��{�b�'���`����9���É�F~�V��>8����wlC�sϢ=q�<�P&<J,ja���t=.��(XQ��ืum8����&�r����{����
�v�=Y���y�)�]"n�n�)�{��jw��,m�˰�:�EvD�{��1ׯvy}G�G�P��a1a��H�2`�����(
�\
 6��<02Ǔyx��͟�ÿ�j/�������,H�����Sv�>_w���}"l=���yu㐠˘0xX4���[	jT��(�q��4O�+Ͱ)�Ѭ�I�1h�uWuu�f_��O	��΁�x�q壨�k3�9�S�ez��@������7��	~��y�����J��~�rv��Tx1�i�FO��2:�V#��9�X��4B��.���G�G�G���-DX��Io�����n�u��l w�����_	5^2( �&���(x]�0%d����Ϳ	(�g�O<�$���\��;(o�T{kg;cn"�P��N���%��a����
�Vas4���*ip��پ����Ɔ�A$FPd��Ң�rI�������˺�=f������������<��olr�¿@��?^�� ��b��lv�M��'��E��Џl�j�w�6������#���9������&�v=jK�\ѩ|�� <��}�4UЉ�,9@��`��#'��t�Qc�m��ڸgn��z��#����@!�����n��%TȇM��ɥ�Q���*B�h_����3(V��u�Fy(�ЏH�X�}FrDuE�����I@=�u-1m�,�С�fe۠_��h�m�S렓�uꄔG�3h�bb�� ���k�<>��]�o�!5���ƨ{)rR���I�� g�zsZƖ����@䊊��A��kcL�YrF顶��$���Ӳ��6-��Oc�28��M5�w}�f��f�nןN?�M%�_���f��{�����ǓH٫S���W}1��t�R��1ыD<5U��T��3�fd*>i�,�'�SN~��!������I>#�������}��_n�-�������F�j��W�3�/���/��0�>Q��h�?��m����~s�jp���_����d���k��>���;��t�z�mX�?�@�{�m��/Z�w��+[�������C�Ͻ<��߫�_�;{��?��c�ġF��[�C�.AH7�Р9�_�a����3W%VR�����T�rE4N���M�^�Xk�0)��x5i[b:uf��ٶX�d��j��Dwf��D�	��YhBNp�\k�u}��k�@Џ����4� rx?�����L���a
/��ȿ�
�SR�b������D���74���ID�`%2Fԙ3e���J�jH(HH�p�:2`���������[`�4��a���1"�2|����`�E�1�A�LQa ��b6>l��v�@�BxB/m�ن"����:Qi5�Ǌ>zHE[�)��w��Uf��u֟g������1eY��~�\�l��)�L��._l6q\�K��/�%���P�p�+��*Z����c�Ћ����p��%MJ�V�П{/��VT��'|�BEa�Q�Vun! ��z
*���g䢒]�{0��P��p�gu����� ︦t�	�9gx�����Ls�_#Rb�F� �t�9�@?�Q.$R�%r��n���i�9]҈�|}:xc���$���X�����dw�F�,S�:'��ǿab���sߧ���7[����!��!���K�ߊ2���7!�!�Z41Z�b ���	訕,K!�sj&E�DL���*+�q��Y�g*u*���j����^�-Y<_��kMY���RK�+D`l^���?������/�h��c��О�HMY$���H�^�^�Y���I�	�;�H�'�co�m�q,��f24���Q���0�($�,|v �.�[V�"�8Y]ů�maT��=���1��_���{������	TltS�Y����F��}I,����Sꡀ]:`�ȓ�x>aZ�<�9������n���#Ӿ�c����'�iI��.T�u�|v�(>)���_���t0��DpN?	��8�K_�POôW�� ��G��1�����}tI��P��n��Qi�Z�1���wIv�-�"!�	&|n�$�YT槮/�:�yK��#���f����gf�,NWL�in��4HҚ�1�!ػ���o���$�\x6SͶ�3�$�e�.�[/ۄ;�\��V�=g�K!.s�V�?�0�!�#��A�3��S$X���Yg���G���c.'�(y���u����x����d�oK��JT^�<�j12(nO\o�Ѷc���<�<��.ONw@$�\)f
Ǫ�%��ʛ�0n)�Wa5^'���q�Z[���%�w��btA�v�!�.�p��w@V�������ӲmY���w�s������2��v�c���ba�ˉSE8�0ٝ��u�K_b8&�L��.�f��D���"�������Af�AX�� t���"��'Fٍ��m�i�|K}���D;��_��}�G��FZ�<p%+9k?��2C9W�a�����dꄉ�����ܳ��b$�D��)ױ8� �l�8�*/(���V���<��RX>v�|�#|���%�ޠ0�.�;!��)o��jjd��S��u���ע�m1�Jϋ����U�P��O&3�{1�Ʉ��a,V�W�,���C���g:�m6񾤖�uɿQ��Az
xxe�\��W<��f6�C�R>���{	���mJ��,�^2�nI��e"6�-���0Bӭ�0�≏�S.$:�	�=[%�	�/[ɫXZ��{w�8��Ǔ�>�3�%��U���7�^E��W��8�b�N�S�����f���9{
CʢP���]� x�Rr��%����{T�3tδ"�Y ^�B�61��0?WFy�O�S�j�6dO+�P)��e��"�#eV��j�+�a�6�[�S�w�x)�>2ۤ&#�,d�m�3�f\IsG!L���7-�[��`-=�c'���=���w�l�,�ʢX��������TL�������`����Jp���%%�T	�x�k%i7�v-���I�,��9��#`'ι�1Kù[�i���iY@7g]�-+�.3�2���z�n����0{P_E��D� ;K�ah	���rk`�|�g 
b�v�,61��1��
*���L�0y�׎h�#A��	���T�	=��Ј�HV������;�$PvWJ�ܒ,+���1���#�;��b	8l�6��\'�75���Ďs�� ;�N�=a~�9/�̏ʔ�|��+7�� G��]u�fw�ulWI�/hS",��7��l<�h)��&�EFY����A 9�'3�Щ� ���R!u>��2�]8�X$���WEj��/����Hm�+8�I77�������V���T�Y2,ؕ���T!��d�:7,U�r�h�>���R����bT���@p[�ST��᫡�9�9#�����/�#�"p�݀�$
�K' *�`�K�V�R�o�R:0�y��@�6|���Q��d���W�^���LMQ�@ɠs&�R��:W��3q�D����H�o��v�Ozcȣ�3���������I
�dE�T��?�h��ۛI���Lg����c���pQ��M&X���rD�����$f��{��U�Ac���g�^�HuyZ�>�~��a?�Z7oK��S�!�l�|k��vs�ކ�#��CFI���4�������k)!UF}I�j�cp;��:'r��?��̱�Ll�s�v�f�,HH����*� b�����@����hN��Q��Y�Ղ����N2<~�N��e|)�[�[Ɯ����HgJ�F������������:?�l��/�]'�\�x^Q^�(%=���2bq+�z|2Ot(H������<۲lJ��غ�'#��Y���
��p"1Xc�^�2�!$"�P%(}����ȖV��f��9׺�x�E�JuT>|����ӗ4�_����O��ІW����O�s٘"�z_�7)���b��X�N���0�6�7����^�w6��B�|�Fs����dp��r�w��4�*�鑵5�u��ˌ%!�YEq�^�Z`ƓƷ�k��~f:C���1���/;��w1��5�&�p׭��*�o;���}d��/,�3����I�*�"�B���zt�"�l��,�\���77�^.I�<-�>>5LERW�d�x!�]�d�f�g�G9��@�L{I�i�rs�
Ҿ��Kz�g�B�A�ke�	����K>��1��#y��Q���N7���g�����������˝W�o � �%���3�,�IU_�{+S��%���{���d��ә�f�hwU%I����[) -[7ҌAxү�1YC���.�0~gWJ��6	�<���~x/]���C�kVhRR��{E���t�ᙁdB��j!����;nўe�W�q#i��և�$"�Se���	�4�������{�(�3.̛�[�,e�e�-��]�Y�˼�f�k��Yҧ�����?nlf������������-]�_�]��[�5�VJ�2�4���֌τ�#]u��E|)�]��xVg��̷���Yق(��%	Nćԅ�x�")���x�O�AU�f��2�u��%}�Oq���t�/���˙%�y���|P+}��|F&�M���)H������o>��{N {���X �֙g����}�
ũk�i�Z~��������8w�_2�!X{{Cq����)	ډO�{�	Z�1ݭp�"��	j�(����kn�6>�~��)�"%�9��H����*�ɤ��� ��r���O�#��!����K_�Ǻ� ��(9���1�8���b� �v�PA�Xn��{��9T�R�5r��X�J>[��l+��D=����=xTV��x�M��9Ю����*7���(�{A4_��v6����(_��l%���yy�ْ9y�'��%���@�oa�V��F�fQ�J&-�U$�,����ӟzp�A��?0���n-�k�������%�^-����m��Q_�snvQxn�gN�ל�H�>"$�S�8��ܡ�2����G烆�i���S��*"��e�
j��*�\/�p<�?�wW��(�;M�����][c��"�g��]��0J�����CGm�G��(����A�']�|�'���TNB���'`0O����a@��q�e>��~��[D�E�%|�\F��ׅpc >w@�"�|*ܐ�f��q"�F�gI��'�'"��Ş{ ,�JeB5R�w��'.�k�f׈�C׹w�6��pʙ���p���g�ѩ��-��s�@����#c��
Gʣ]��%r�so4��SN4���쀙��4(M�O3�)��C呡ӈM�1��,6��j�Y����B<D�ɡ/}���j8Ew ��L�G�b[pi�x�D����O�
��O�Z���n����?dc�@B3J�I�aQ���[o�^hso4�10 �B���^�`8{b=ږ����ߎ�� :{~�sʠ������xr08�L� ���5��o��A㹌� �a�B���AV��3!"!���.js���D�f���1�������`�4�#I5����� ��v�Բ� �a0HD���ݕ�X�ꞭTD�g�2~�	F�%�D��s-
�H��@�q%o	ta�ރX�� t�Qr0���^L�de9�htu���G����8���R�2h���6�S00�������P3	0;�]�Az5� �J����F[��-%w���F3�����?��,�+te�pH�n��4?���O��6��O�G�	{�pX��^/���=�pI8�iu�@D�q���]N;��Sj�i�r����2Zͪ�e��M�T�aJ������!˨�b{����2)���Fb�ls�J�A�_�1���pKn�M���l�H�j���"��Q�@�+X�����b�aޝu�<r}4�Ɔ)�<�:��v���3U�����c�O06̋
�<,���(��K����1�`��_N2"*��y8�xDAҔ�=��	(o����A������rp���sv2���;���8�ǳ5�=D�jW�[���]@���ƪ��Ð
0E����[�J	��w(K��FZq�N$!�0P���,�$�n�Y<%���6R��C����ȶQE�ޣZ���T�����Lx���d���I��um�P��]S1�� �l3yl;tt��R�hq���{�Tƭ4�t���`��x0:TJukn�`�	Ն���FNԊ��qM�m�[zfye�/�b����p_���g�'YYkMs�B��W8k�n����pHoH�PH����
��T�$tr������2Z���:��Ra;o���l�i��q#�ɲ������e5��?Xe>��5j�G3��Ne8s���J������mWB6�r�(�u��X	��cu�<�I>􉈞����P���׊%���o��8���,�)�5��m_}ۿѷ��ηn���z�Q�o��Q�1
�~v�~��Aɠ�w"��L&����,%k_:~r������)��1p������M��[Oa���wUXI��*h,<\(s��Q��Th�D����Ԁ�j����q��>Q�R2�Y��.�T�!�wm����H
4-&+�\��ҩ5h�_5K��!U�\38Wi�(�M��HT�V�]�m�bv6���9� �A-+
�qx���l3I�,U0�X	�i�� zA5���c.U,۾�8�\Ky��}@wJVn�T��������"�*O�+����Mпq(���a1ujٵ%?��ߔ�z�S�a���ߌ[�s�#n|�ݏE��	+��{�u�;���o����/�m��?X��}��|�;r���.N�	��7��F����|��
�`&g��h�G`��(���wB~LO���O��o�?ƕl���uq՝&�	~k,�]���9���*�� P����~�R���oHG��a��q��!�{�N[�֘e��\ͼ�&�`F��`�,<p'���Z����=|����_�)�"��NdŸ\�	��,=bt���q�'.;w=�'�������������v�L�k�K�b����}f���m��U4J��t��
�u�����O�}X�t$�G$-3<}'-���ŕHR�2�(ܠ���u�n=���f��S�u�6V��l,�?>N�;��]'�� O�T8�w57���v�"�ɖ�����bX]~a1�&���]Ҽ<���Ar�YG�^�h�e4�2伵�z��W4���u�ZG����T3寁*���)�@�KOGkk�+;�!T���hB���ʹʹ^3���z�B�75d�l (MX�<�.u�k��׍ݻ�<��⼓J������/���~�a�<�[�\���(i���γ�mS;R�cf��e�"�y����(2��FqBg�	��{���G��m�\���I�5A�p(�h���@ �O�1���q,�9"@oG}� I��b����9d>�f^�k����s�6q��y 6�4��$�ar�gO�t���	�^�~M��P ��]"�\��i�>]�ڙ�C�,N�BO�嵠,��^�w �@_rt�#����v��M᩟�Y� ��i[�.�cy�1#�2�5q7 �Q�;W|j��I웊sS�/�XLA��l�Mr�Z��������s����]Y���d6�vr�c�3�|�L9��Fy,�#�����]h�����n*�e@�@��0����M5�,�S�+�iD�d\r��@J��搓���9f[�삿�E�l���D�}�*^�u����t���^l;�Z���?ۂ�<��Q�U�Z��j�@��+�nh{8wTNv��ΐ��*�e}�lR�۳�O&�xn�z�Z��p$,��`�� ���G����w9	,z�A=����R�چu���ѷ[XL�*�BP`�㯋3�)�:���O(��Ő"�(��J+������̀��@���O۲��t���������pC��R~����K�mo���Z�R�K�h�T��W��X�\vL��C��Xp$��Ѐ��¦DyC���eCn'��l�Xk�?$$-�e�ΡO�zl�a���1v:)dDo��TX�n+��P4�-�I��G2bA���:L^|(c�8B�;{���K�?�ڃ���*��3 S�{~�ZF*���oǸ��ye�7��7�0ܶ{=� )�m)�٤EDӆ�w�+f^�O�LG�b?�/ZQfL�Q&����/A[܁N`�W��V�l�Ⱦ�3��_�ߜ�P7�o&�T�6޳��:��_��%�AQ,�<�3���@�X�74��J`w�۲}ߙ`����8.]2�9�A�!��#�Q����>��d�w��Eԥ]>�@^�0[�#[� ��g���66LcA46AR�����+�A�9�ZJ���Y�E�m��u�n��qN�Lf?�w|	dˁ����)�Ƞ�lwB�&Tz��ȳ�{P��i���0v�U�|��1FKo�SL��Y�0ʚ�ܕ���� ��cC�ĕ��6X�Ո�vډ�-�[\��M< ��I�]4�^O8.q ���`w����V�	�q���TYm�S+����^�Q��B��?f�#3޵%��l>��'TDޮJ�ܨ�Y�qՁqu�#A�{rC,���p�?I������q��o}��Y��m<��X��>F:;�y����|���9=�-��iZ������y��qM��܄�^��Y��(���/�#�&�&�_y�E}����7XvGF�_��✿�c`��x$c�,�d��ҡ��N�)�b�x��Zl	*��#�!��=�~�����,���@�0Z갥����~�q����A^�c_h�:�11j���.	��!`/5@=�5K�Q5<�n_.D�mg4D�-]cO�}��ʘ�W��/鰻)�x�<^8-ْ���?�'�7~$��n��?/~�A5���ƨ�H��+�$S�
,~Q��e�7��������:�J��]6���T�T���Su�Z���� c�qUh�w[���Ә޾52����s�����mg�%�Zf�7���7�;l��W�l.g7n4K�:
j��o1g�O	��e�]�Ye��aV��E��M�f�*�m�{������\@�XHu�\Lq���][��U�\���qc�
�uE� Mu�^���(n��6��A\�-l��e7�[Oz\��ş$�W���P����=�E��fb,'�WWݬ�v���H��H��H��H��H��H��H��H��H��H��H����jQ �  