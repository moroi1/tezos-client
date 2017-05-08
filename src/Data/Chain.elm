module Data.Chain exposing (..)

import Date exposing (Date)
import Dict exposing (Dict)
import Json.Decode as Decode
import Json.Decode.Pipeline as Decode
import Set


type alias Base58CheckEncodedSHA256 =
    String


type alias BlockID =
    Base58CheckEncodedSHA256


type alias OperationID =
    Base58CheckEncodedSHA256


type alias NetID =
    Base58CheckEncodedSHA256


type alias SourceID =
    Base58CheckEncodedSHA256


type alias Signature =
    Base58CheckEncodedSHA256


type alias Fitness =
    String


type alias Timestamp =
    Date


type alias Block =
    { hash : BlockID
    , predecessor : BlockID
    , fitness : List Fitness
    , timestamp : Timestamp
    , operations : List (List OperationID)
    , net_id : NetID
    , level : Level
    }


type alias Operation =
    { hash : OperationID
    , netID : NetID
    , data : String
    }


type alias Level =
    Int


type alias Nonce =
    String


type SubOperation
    = Unknown Decode.Value
    | Endorsement BlockID Int
    | SeedNonceRevelation Level Nonce


type alias ParsedOperation =
    { hash : OperationID
    , net_id : NetID
    , source : SourceID
    , operations : List SubOperation
    , signature : Signature
    }


type alias BlockOperations =
    List (List ParsedOperation)


type alias BlocksData =
    List (List Block)


type alias Model =
    { heads : List BlockID
    , blocks : Dict BlockID Block
    , operations : Dict OperationID Operation
    , parsedOperations : Dict OperationID ParsedOperation
    , blockOperations : Dict BlockID (List ParsedOperation)
    }


init : Model
init =
    { heads = []
    , blocks = Dict.empty
    , operations = Dict.empty
    , parsedOperations = Dict.empty
    , blockOperations = Dict.empty
    }


blockNeedsOperations : Model -> BlockID -> Bool
blockNeedsOperations model blockHash =
    not (Dict.member blockHash model.blockOperations)


blocksNeedingOperations : Model -> List BlockID
blocksNeedingOperations model =
    let
        blockHashSet =
            Dict.toList model.blocks |> List.map Tuple.first |> Set.fromList

        blockOperHashSet =
            Dict.toList model.blockOperations |> List.map Tuple.first |> Set.fromList
    in
        Set.diff blockHashSet blockOperHashSet |> Set.toList


addBlockOperations : Model -> BlockID -> BlockOperations -> Model
addBlockOperations model blockhash operations =
    let
        blockOperations =
            Dict.insert blockhash (List.concat operations) model.blockOperations
    in
        { model | blockOperations = blockOperations }


loadBlocks : Model -> BlocksData -> Model
loadBlocks model blocksData =
    let
        newBlocks =
            List.foldl addChainBlocks model.blocks blocksData
    in
        { model | blocks = newBlocks }


loadHeads : Model -> BlocksData -> Model
loadHeads model headsData =
    let
        newModel =
            loadBlocks model headsData

        heads : List BlockID
        heads =
            List.map List.head headsData
                |> List.filterMap identity
                |> List.map .hash
    in
        { newModel | heads = heads }


addBlock : Block -> Dict BlockID Block -> Dict BlockID Block
addBlock block blocks =
    Dict.insert block.hash block blocks


addChainBlocks : List Block -> Dict BlockID Block -> Dict BlockID Block
addChainBlocks chain blocks =
    List.foldl addBlock blocks chain


head : Model -> Maybe BlockID
head model =
    List.head model.heads


{-| Get list of saved blocks starting with the block with given hash and
following predecessor links. This only finds blocks already in the dict.
-}
getBranchList : Model -> BlockID -> List Block
getBranchList model blockhash =
    let
        helper hash blockList =
            Dict.get hash model.blocks
                |> Maybe.map (\block -> helper block.predecessor (block :: blockList))
                |> Maybe.withDefault blockList
    in
        helper blockhash [] |> List.reverse


loadOperation : Model -> Operation -> Model
loadOperation model operation =
    let
        newOperations =
            Dict.insert operation.hash operation model.operations
    in
        { model | operations = newOperations }


loadParsedOperation : Model -> OperationID -> ParsedOperation -> Model
loadParsedOperation model operationId operation =
    let
        newParsed =
            Dict.insert operationId operation model.parsedOperations
    in
        { model | parsedOperations = newParsed }



-- Decoders


decodeBlocks : Decode.Decoder BlocksData
decodeBlocks =
    Decode.field "blocks" (Decode.list (Decode.list decodeBlock))


decodeBlock : Decode.Decoder Block
decodeBlock =
    Decode.succeed Block
        |> Decode.required "hash" Decode.string
        |> Decode.required "predecessor" Decode.string
        |> Decode.required "fitness" (Decode.list Decode.string)
        |> Decode.required "timestamp" decodeTimestamp
        |> Decode.optional "operations" (Decode.list (Decode.list Decode.string)) [ [] ]
        |> Decode.required "net_id" Decode.string
        |> Decode.required "level" Decode.int


decodeTimestamp : Decode.Decoder Timestamp
decodeTimestamp =
    Decode.string
        |> Decode.map Date.fromString
        |> Decode.map (Result.withDefault (Date.fromTime 0))


decodeBlockOperationDetails : Decode.Decoder BlockOperations
decodeBlockOperationDetails =
    -- I don't understand why the RPC response data has two levels of lists. Anyway...
    Decode.field "ok" (Decode.list (Decode.list decodeParsedOperation))


decodeParsedOperation : Decode.Decoder ParsedOperation
decodeParsedOperation =
    Decode.succeed ParsedOperation
        |> Decode.required "hash" Decode.string
        |> Decode.required "net_id" Decode.string
        |> Decode.required "source" Decode.string
        |> Decode.required "operations" (Decode.list decodeSubOperation)
        |> Decode.required "signature" Decode.string


decodeSubOperation : Decode.Decoder SubOperation
decodeSubOperation =
    Decode.oneOf
        [ decodeEndorsement
        , Decode.map Unknown Decode.value
        ]


decodeEndorsement : Decode.Decoder SubOperation
decodeEndorsement =
    Decode.field "kind" Decode.string
        |> Decode.andThen
            (\kind ->
                case kind of
                    "endorsement" ->
                        (Decode.map2 Endorsement
                            (Decode.field "block" Decode.string)
                            (Decode.field "slot" Decode.int)
                        )

                    "seed_nonce_revelation" ->
                        Decode.map2 SeedNonceRevelation
                            (Decode.field "level" Decode.int)
                            (Decode.field "nonce" Decode.string)

                    _ ->
                        decodeDebug "bad kind" |> Decode.map Unknown
            )


decodeLevel : Decode.Decoder Int
decodeLevel =
    Decode.at [ "ok", "level" ] Decode.int


decodeParsedOperationResponse : Decode.Decoder ParsedOperation
decodeParsedOperationResponse =
    Decode.field "ok" decodeParsedOperation


getBlockOperationIDs : Block -> List OperationID
getBlockOperationIDs block =
    List.concatMap identity block.operations


{-| This decoder is useful for debugging. It is basically the same as just
`Decode.value` except that it has the side-effect of logging the decoded value
along with a message.
-}
decodeDebug : String -> Decode.Decoder Decode.Value
decodeDebug message =
    Decode.value
        |> Decode.andThen
            (\value ->
                let
                    _ =
                        Debug.log message value
                in
                    Decode.value
            )