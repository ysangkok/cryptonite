{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Crypto.PubKey.ECC.P256K1 (
    Point (..),
    Scalar (..),
    scalarGenerate,
    scalarToPoint,
    scalarFromInteger,
    scalarToBinary,
    pointToBinary,
    pointFromBinary,
    pointToTPoint,
    pointFromTPoint,
    pointDh,
    parseDerSignature,
    rfc6979,
) where

import Control.Monad (unless)
import Crypto.Error.Types (CryptoError (..), CryptoFailable (..), throwCryptoError)
import Crypto.Hash (Digest, SHA256)
import Crypto.Number.Serialize (i2osp, os2ip, i2ospOf)
import Crypto.PubKey.ECC.ECDSA (PrivateKey (PrivateKey), Signature (Signature))
import qualified Crypto.PubKey.ECC.Types as T
import Crypto.Random (MonadRandom, getRandomBytes)
import Crypto.Random.Entropy (getEntropy)
import Data.ByteArray (ByteArray, ByteArrayAccess, convert)
import qualified Data.ByteString as BS
import Data.ByteString (ByteString)
import Data.ByteString.Short (ShortByteString, fromShort, toShort)
import Foreign
import Foreign.C
import System.IO.Unsafe (unsafeDupablePerformIO, unsafePerformIO)

-- A pub key in libsecp256k1 takes up 64 bytes, so we can use this
newtype Bytes64 = Bytes64 {getBytes64 :: ShortByteString}
    deriving (Read, Show, Eq, Ord)

instance Storable Bytes64 where
    sizeOf _ = 64
    alignment _ = 1
    peek p = Bytes64 . toShort <$> packByteString (p, 64)
    poke p (Bytes64 k) = useByteString (fromShort k)
        $ \(b, _) -> copyArray (castPtr p) b 64

-- A scalar in libsecp256k1 takes up 32 bytes, so we can use this
newtype Bytes32 = Bytes32 {getBytes32 :: ShortByteString}
    deriving (Read, Show, Eq, Ord)

instance Storable Bytes32 where
    sizeOf _ = 32
    alignment _ = 1
    peek p = Bytes32 . toShort <$> packByteString (p, 32)
    poke p (Bytes32 k) = useByteString (fromShort k)
        $ \(b, _) -> copyArray (castPtr p) b 32

-- private keys are scalars
newtype Scalar = Scalar (ForeignPtr Bytes32)

-- public keys are points
newtype Point = Point (ForeignPtr Bytes64)

-- secp256k1 needs a context, we use this opaque type to represent it
data Ctx

instance Eq Point where
    a == b = (pointToBinary a :: ByteString) == pointToBinary b

-- length of retured ByteArray is 32
scalarToBinary :: ByteArray binary => Scalar -> binary
scalarToBinary (Scalar fk) = convert $ fromShort $ getBytes32 $ unsafePerformIO $ withForeignPtr fk peek

-- | This can be used to derive the public key corresponding to a given private key.
-- | Should never return CryptoFailed since it is not possible to construct an invalid Scalar.
-- Based on derivePubKey in secp256k1-haskell
scalarToPoint :: Scalar -> CryptoFailable Point
scalarToPoint (Scalar fk) =
    withContext $ \ctx -> withForeignPtr fk $ \k -> do
        fp <- mallocForeignPtr
        ret <- withForeignPtr fp $ \p -> ecPubKeyCreate ctx p k
        if isSuccess ret then
            return $ CryptoPassed $ Point fp
        else
            return $ CryptoFailed CryptoError_EcScalarOutOfBounds

-- | Randomly generate a new scalar.
-- | Will keep retrying until valid results are found.
scalarGenerate :: MonadRandom randomly => randomly Scalar
scalarGenerate = do
    bs <- getRandomBytes 32
    case scalarFromInteger $ os2ip (bs :: ByteString) of
        CryptoPassed scalar -> return scalar
        CryptoFailed _ -> scalarGenerate

-- | secp256k1 scalar from given integer.
-- | Returns EcScalarOutOfBounds when passed scalar deemed
-- | to be invalid by libsecp256k1.
-- Based on secKey in secp256k1-haskell
scalarFromInteger :: Integer -> CryptoFailable Scalar
scalarFromInteger int =
    case maybeBS of
        Just bs -> withContext $ \ctx -> do
            fp <- mallocForeignPtr
            ret <- withForeignPtr fp $ \p -> do
                poke p (Bytes32 (toShort bs))
                ecSecKeyVerify ctx p
            if isSuccess ret
                then return $ CryptoPassed $ Scalar fp
                else return $ CryptoFailed CryptoError_EcScalarOutOfBounds
        Nothing -> CryptoFailed CryptoError_EcScalarOutOfBounds
    where
        maybeBS = i2ospOf 32 int

-- | Point (public key) from given ByteArrayAccess.
-- | Public key must be encoded in compressed Bitcoin format (33 bytes).
-- | Returns CryptoFailed if invalid compressed point is passed.
-- Based on importPubKey in secp256k1-haskell
pointFromBinary :: ByteArrayAccess ba => ba -> CryptoFailable Point
pointFromBinary ba = do
    let bs = convert ba
    withContext $ \ctx -> useByteString bs $ \(b, l) -> do
        fp <- mallocForeignPtr
        ret <- withForeignPtr fp $ \p -> ecPubKeyParse ctx p b l
        if isSuccess ret
            then return $ CryptoPassed $ Point fp
            else return $ CryptoFailed CryptoError_PointFormatInvalid

-- | Compressed public key serialization from given point (public key)
-- | Result is 33 bytes in length.
-- | Throws when unable to serialize, which should never happen.
-- Based on exportPubKey in secp256k1-haskell
pointToBinary :: ByteArray bs1 => Point -> bs1
pointToBinary (Point ptr) = withContext $ \ctx ->
    withForeignPtr ptr $ \p -> alloca $ \l -> allocaBytes z $ \o -> do
        poke l (fromIntegral z)
        ret <- ecPubKeySerialize ctx o l p c
        unless (isSuccess ret) $ throwCryptoError $ CryptoFailed CryptoError_InternalAssumptionFailed
        n <- peek l
        bs <- packByteString (o, n)
        return $ convert bs
    where
        c = 0x0102 :: CUInt -- compressed
        z = 33 -- length of compressed pubkey

{-# NOINLINE fctx #-}
fctx :: ForeignPtr Ctx
fctx = unsafePerformIO $ do
    x <- ecContextCreate 0x0301 -- signVerify
    e <- getEntropy 32
    ret <- alloca $ \s -> poke s (Bytes32 (toShort e)) >> ecContextRandomize x s
    unless (isSuccess ret) $ throwCryptoError $ CryptoFailed CryptoError_InternalAssumptionFailed
    newForeignPtr ecContextDestroy x

{-# INLINE withContext #-}
withContext :: (Ptr Ctx -> IO a) -> a
withContext f = unsafeDupablePerformIO (withForeignPtr fctx f)

isSuccess :: CInt -> Bool
isSuccess (CInt 0) = False
isSuccess (CInt 1) = True
isSuccess _ = throwCryptoError $ CryptoFailed CryptoError_InternalAssumptionFailed

packByteString :: (Ptr a, CSize) -> IO BS.ByteString
packByteString (b, l) = BS.packCStringLen (castPtr b, fromIntegral l)

useByteString :: ByteString -> ((Ptr CUChar, CSize) -> IO a) -> IO a
useByteString bs f =
    BS.useAsCStringLen bs $ \(b, l) -> f (castPtr b, fromIntegral l)

-- | ECDH shared secret from given Scalar (private key) and
-- | given Point (public key).
-- | Returns a ByteArray of 32 bytes.
pointDh :: ByteArray binary => Scalar -> Point -> binary
pointDh (Scalar sfp) (Point pfp) =
    withContext $ \ctx ->
        withForeignPtr sfp $ \p ->
            withForeignPtr pfp $ \s -> do
                fp <- mallocForeignPtr
                withForeignPtr fp $ \o -> do
                    ret <- ecEcdh ctx o s p nullPtr nullPtr
                    unless (isSuccess ret)
                        $ throwCryptoError $ CryptoFailed
                            CryptoError_EcScalarOutOfBounds
                    bs <- packByteString (o, 32)
                    return $ convert bs

-- | Convenience method for converting from the generic Point type to a libsecp256k1 point.
-- | Throws if the point is not valid on secp256k1, for example when passed the PointO.
pointFromTPoint :: T.Point -> Point
pointFromTPoint T.PointO = throwCryptoError $ CryptoFailed CryptoError_PointCoordinatesInvalid
pointFromTPoint (T.Point x y) = withContext $ \ctx ->
    useByteString bs $ \(buf, _) -> do
        fp <- mallocForeignPtr
        withForeignPtr fp $ \p -> do
            ret <- ecPubKeyParse ctx p buf 65
            if isSuccess ret
                then return $ Point fp
                else throwCryptoError $ CryptoFailed CryptoError_InternalAssumptionFailed
    where
        Just bx = i2ospOf 32 x
        Just by = i2ospOf 32 y
        bs = BS.concat [BS.pack [0x04], bx, by]

-- | Convenience method for converting from the secp256k1 specific Point type
-- | to the generic Point type.
-- | Returns CryptoFailed (failure) when unable to serialize. Should never happen.
-- | Returns CryptoPassed (success) otherwise.
pointToTPoint :: Point -> CryptoFailable T.Point
pointToTPoint (Point fp) = withContext $ \ctx ->
    withForeignPtr fp $ \p ->
        alloca $ \outputlen -> allocaBytes z $ \o -> do
            poke outputlen (fromIntegral z)
            ret2 <- ecPubKeySerialize ctx o outputlen p flags
            if not $ isSuccess ret2 then
                return $ CryptoFailed CryptoError_InternalAssumptionFailed
            else do
                n <- peek outputlen
                if n /= 65 then
                    return $ CryptoFailed CryptoError_InternalAssumptionFailed
                else do
                    outbs <- packByteString (o, n)
                    let (_, coords) = BS.splitAt 1 outbs
                    let (bx, by) = BS.splitAt 32 coords
                    return $ CryptoPassed $ T.Point (os2ip bx) (os2ip by)
    where
        flags = 0x0002 :: CUInt -- uncompressed
        z = 65 -- length of uncompressed pubkey

-- | Parse DER-encoded signature. It's length is 71 bytes in average.
-- | Returns CryptoFailed if the signature is in an invalid format.
-- | The signature returns is in a generic format with r and s values easily
-- | accessible.
-- stolen from secp256k1-haskell test suite
parseDerSignature :: ByteString -> CryptoFailable Signature
parseDerSignature bs =
    withContext $ \ctx ->
        BS.useAsCStringLen bs $ \(d, dl) -> alloca $ \sigbuf -> do
            ret1 <- ecdsaSignatureParseDer ctx sigbuf (castPtr d) (fromIntegral dl)
            if isSuccess ret1
                then do
                    alloca $ \pc -> do
                        ret2 <- ecdsaSignatureSerializeCompact ctx pc sigbuf
                        if isSuccess ret2 then do
                            b64 <- peek pc
                            let (r, s) = BS.splitAt 32 $ fromShort $ getBytes64 b64
                            return $ CryptoPassed $ Signature (os2ip r) (os2ip s)
                        else
                            return $ CryptoFailed CryptoError_InternalAssumptionFailed
                else do
                    return $ CryptoFailed CryptoError_SignatureInvalid


-- | Calculate nonce according to RFC 6979 with HMAC-SHA256.
-- | Takes
-- | * a message digest,
-- | * a private key (generic format),
-- | * a counter (CUInt)
-- | The counter is usually set to 0, but can be incremented if the resulting nonce
-- | cannot be used for producing a valid signature.
-- see src/secp256k1.c revision e541a90 line 475
rfc6979 :: Digest SHA256 -> PrivateKey -> CUInt -> Integer
rfc6979 digest (PrivateKey _ pk) counter =
    unsafePerformIO $ do
        let digestbs = convert digest
        fpd <- mallocForeignPtr
        withForeignPtr fpd $ \digest32 -> do
            poke digest32 (Bytes32 (toShort digestbs))
            fpk <- mallocForeignPtr
            withForeignPtr fpk $ \key32 -> do
                poke key32 (Bytes32 (toShort (i2osp pk)))
                fp <- mallocForeignPtr
                withForeignPtr fp $ \nonce32 -> do
                    res <- secp256k1_rfc6979 nonce32 digest32 key32 nullPtr nullPtr counter
                    unless (isSuccess res) $ throwCryptoError $ CryptoFailed CryptoError_EcScalarOutOfBounds
                    bs <- packByteString (nonce32, 32)
                    return $ os2ip $ bs

type RFC6979Fun
    = Ptr Bytes32 -- nonce output (32 bytes)
    -> Ptr Bytes32 -- msg hash input (32 bytes)
    -> Ptr Bytes32 -- key input (32 bytes)
    -> Ptr CUChar -- algo (can be null)
    -> Ptr CUChar -- data void pointer (can be null)
    -> CUInt
    -> IO CInt

secp256k1_rfc6979 :: RFC6979Fun
secp256k1_rfc6979 = mkInner ptr_secp256k1_rfc6979

------------------------------------------------------------------------
-- Foreign bindings
------------------------------------------------------------------------

foreign import ccall "secp256k1.h secp256k1_ec_pubkey_serialize"
    ecPubKeySerialize
        :: Ptr Ctx
        -> Ptr CUChar -- ^ array for encoded public key, must be large enough
        -> Ptr CSize -- ^ size of encoded public key, will be updated
        -> Ptr Bytes64 -- pubkey
        -> CUInt -- context flags
        -> IO CInt

foreign import ccall "secp256k1.h secp256k1_context_randomize"
    ecContextRandomize
        :: Ptr Ctx
        -> Ptr Bytes32
        -> IO CInt

foreign import ccall "secp256k1.h secp256k1_context_create"
    ecContextCreate
        :: CUInt -- ctx flags
        -> IO (Ptr Ctx)

foreign import ccall "secp256k1.h &secp256k1_context_destroy"
    ecContextDestroy :: FunPtr (Ptr Ctx -> IO ())

foreign import ccall "secp256k1.h secp256k1_ec_pubkey_create"
    ecPubKeyCreate
        :: Ptr Ctx
        -> Ptr Bytes64 -- Point
        -> Ptr Bytes32 -- Scalar
        -> IO CInt

foreign import ccall "secp256k1.h secp256k1_ec_seckey_verify"
    ecSecKeyVerify
        :: Ptr Ctx
        -> Ptr Bytes32 -- Scalar
        -> IO CInt

foreign import ccall "secp256k1.h secp256k1_ec_pubkey_parse"
    ecPubKeyParse
        :: Ptr Ctx
        -> Ptr Bytes64 -- pubkey
        -> Ptr CUChar -- encoded public key array
        -> CSize -- size of encoded public key array
        -> IO CInt

foreign import ccall "secp256k1.h secp256k1_ecdh"
    ecEcdh
        :: Ptr Ctx
        -> Ptr Bytes32 -- output (32 bytes)
        -> Ptr Bytes64 -- pubkey
        -> Ptr Bytes32 -- privkey
        -> Ptr Int -- hash function pointer. int is just bogus
        -> Ptr CUChar -- arbitrary data that is passed through
        -> IO CInt

foreign import ccall "secp256k1.h secp256k1_ecdsa_signature_serialize_compact"
    ecdsaSignatureSerializeCompact
        :: Ptr Ctx
        -> Ptr Bytes64 -- output compact sig
        -> Ptr Bytes64 -- sig
        -> IO CInt

foreign import ccall "secp256k1.h secp256k1_ecdsa_signature_parse_der"
    ecdsaSignatureParseDer
        :: Ptr Ctx
        -> Ptr Bytes64
        -> Ptr CUChar -- encoded DER signature
        -> CSize -- size of encoded signature
        -> IO CInt

foreign import capi "secp256k1.h value secp256k1_nonce_function_rfc6979"
    ptr_secp256k1_rfc6979 :: FunPtr RFC6979Fun

foreign import ccall "dynamic" mkInner :: FunPtr RFC6979Fun -> RFC6979Fun
