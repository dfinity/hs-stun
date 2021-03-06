{-# LANGUAGE RecordWildCards #-}
module Network.Stun.Base where

import           Control.Monad
import           Data.Bits
import qualified Data.ByteString as BS
import           Data.Digest.CRC32
import           Data.Serialize
import           Data.Word

type Method = Word16

data MessageClass = Request
                  | Success
                  | Failure
                  | Indication
                    deriving (Show, Eq)

data Attribute = Attribute { attributeType :: {-# UNPACK #-} !Word16
                           , attributeValue :: BS.ByteString
                           } deriving (Show, Eq)


data TransactionID = TID {-# UNPACK #-} !Word32
                         {-# UNPACK #-} !Word32
                         {-# UNPACK #-} !Word32
                         deriving (Show, Read, Eq)

data Message = Message { messageMethod :: !Method
                       , messageClass  :: !MessageClass
                       , transactionID :: !TransactionID
                       , messageAttributes   :: [Attribute]
                       , fingerprint   :: !Bool
                       } deriving (Eq, Show)

-- | "magic cookie" constant
cookie :: Word32
cookie = 0x2112A442

data AttributeError = AttributeWrongType | AttributeDecodeError
                                           deriving (Show, Eq)

class Serialize a => IsAttribute a where
    attributeTypeValue :: a -> Word16
    toAttribute        :: a -> Attribute
    toAttribute x = Attribute { attributeType = attributeTypeValue x
                              , attributeValue = encode x
                              }
    fromAttribute      :: Attribute -> Either AttributeError a
    fromAttribute (Attribute tp vl) = x
      where x = if tp == attributeTypeValue ((\(Right r) -> r) x) then
                  case decode vl of
                      Left _  -> Left AttributeDecodeError
                      Right r -> Right r
                else Left AttributeWrongType

findAttribute :: IsAttribute a => [Attribute] -> Either AttributeError [a]
findAttribute [] = Right []
findAttribute (x:xs) = case fromAttribute x of
    Right r -> (r :) `fmap` findAttribute xs
    Left AttributeWrongType -> findAttribute xs
    Left AttributeDecodeError -> Left AttributeDecodeError


putAttribute :: Attribute -> PutM ()
putAttribute Attribute{..} = do
    putWord16be attributeType
    putWord16be (fromIntegral $ BS.length attributeValue)
    putByteString attributeValue
    -- padding:
    replicateM_ (negate (BS.length attributeValue) `mod` 4) $ putWord8 0
    return ()

getAttribute :: Get Attribute
getAttribute = do
    attributeType <- getWord16be
    leng <- getWord16be
    attributeValue <- getBytes (fromIntegral leng)
    -- consume padding:
    _ <- replicateM (negate (fromIntegral leng) `mod` 4) $ getWord8
    return Attribute{..}

instance Serialize Attribute where
    put = putAttribute
    get = getAttribute

encodeMessageType :: Method -> MessageClass -> Word16
encodeMessageType method messageClass =
    (method .&. 0xf)                    -- least 4 bits remain the same
    .|. (c0 `shiftL` 4)                 -- bit 5 is class low bit
    .|. ((method .&. 0x70)  `shiftL` 1) -- next 3 bits are offset by 1
    .|. (c1 `shiftL` 8)                 -- bit 9 is class high bit
    .|. ((method .&. 0xf80) `shiftL` 2) -- highest 5 bits are offset by 2
    -- most significant 2 bits remain 0
  where
    (c1, c0) = case messageClass of
        Request    -> (0,0) :: (Word16, Word16)
        Success    -> (1,0)
        Failure    -> (1,1)
        Indication -> (0,1)

decodeMessageType :: Word16 -> (Method, MessageClass)
decodeMessageType word = (method, mClass)
  where
    mClass = case (c1, c0) of
        (False, False) -> Request
        (True , False) -> Success
        (True , True ) -> Failure
        (False, True ) -> Indication
    c0 = testBit word 4
    c1 = testBit word 8
    method =
        (word .&. 0xf)                     -- least 4 bits remain the same
        .|. ((word .&. 0xe0)  `shiftR` 1)  -- next 3 bits are offset by 1
        .|. ((word .&. 0x3e00) `shiftR` 2) -- highest 5 bits are offset by 2


fingerprintXorConstant :: Word32
fingerprintXorConstant = 0x5354554e

fingerprintAttribute :: Word32 -> Attribute
fingerprintAttribute crc = Attribute { attributeType = 0x8028
                            , attributeValue = encode $ crc `xor` fingerprintXorConstant
                            }

putPlainMessage :: Int -> Message -> PutM ()
putPlainMessage plusSize Message{..} = do
    putWord16be (encodeMessageType messageMethod messageClass)
    let messageBody = runPut . void $ mapM put messageAttributes
    let messageLength = (fromIntegral $ BS.length messageBody + plusSize)
    putWord16be messageLength
    putWord32be cookie
    let (TID tid1 tid2 tid3) = transactionID
    putWord32be tid1
    putWord32be tid2
    putWord32be tid3
    putByteString messageBody

putMessage :: Message -> PutM ()
putMessage m | fingerprint m = do
    -- The rfc demands that we crc32 the message until the beginning of the
    -- fingerprint attribute, but with the message length already set to the
    -- length of the entire message (including fingerprint), so we pass the
    -- length of the fingerprint attribute (8 byte) to be added to the length
    let msg = runPut $ putPlainMessage 8 m
    putByteString msg
    put . fingerprintAttribute . crc32 $ msg
             -- No fingerprint demanded
             | otherwise = putPlainMessage 0 m

getMessage :: Get Message
getMessage = do
    (mlen, msg) <- lookAhead $ do
        tp <- getWord16be
        guard $ 0xc000 .&. tp == 0 -- highest 2 bits are always 0
        let (messageMethod, messageClass) = decodeMessageType tp
        messageLength <- fromIntegral `fmap` getWord16be
        guard $ messageLength `mod` 4 == 0
        guard . (== cookie) =<< getWord32be -- "Magic cookie"
        transactionID <- liftM3 TID getWord32be getWord32be getWord32be
        messageAttributes <- isolate messageLength getMessageAttributes
        let fingerprint = False
        return (messageLength, Message{..})
    case reverse . messageAttributes $ msg of -- Fingerprint has to be the last
                                              -- attribute
        (Attribute 0x8028 fp :_) -> do
            start <- getBytes ( 20    -- header length
                              + mlen  -- plus message length
                              - 8     -- but only up to the beginning of
                                      -- fingerprint
                              )
            let crc = fingerprintXorConstant `xor` crc32 start
            label "fingeprint does not match" $ guard (encode crc == fp)
            return msg{ fingerprint = True
                      , messageAttributes = init . messageAttributes $ msg
                      }
        _ -> return msg
  where
    getMessageAttributes = isEmpty >>= \e -> if e then return [] else go
    go = do
        attr <- getAttribute
        empty <- isEmpty
        rest <- if empty then return [] else go
        return $ attr:rest

instance Serialize Message where
    put = putMessage
    get = getMessage

-- Helper for debugging bit-twiddling
showBits :: Bits a => a -> [Char]
showBits a = reverse [if testBit a i then '1' else '0' | i <- [0.. bitSize a - 1]]
