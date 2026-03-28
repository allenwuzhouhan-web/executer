import Foundation

// MARK: - Humor Messages Structure

struct HumorMessages {
    let thinkingMessages: [String]
    let toolMessages: [String: [String]]
    let genericToolMessages: [String]
    let successPrefixes: [String]
    let healthyMessages: [String]
    let diskWarningMessages: [String]
}

// MARK: - Language Definition

enum AppLanguage: String, CaseIterable, Codable {
    case english = "en"
    case chinese = "zh"
    case russian = "ru"
    case spanish = "es"
    case french = "fr"
    case japanese = "ja"

    var flag: String {
        switch self {
        case .english:  return "🇺🇸"
        case .chinese:  return "🇨🇳"
        case .russian:  return "🇷🇺"
        case .spanish:  return "🇪🇸"
        case .french:   return "🇫🇷"
        case .japanese:  return "🇯🇵"
        }
    }

    var displayName: String {
        switch self {
        case .english:  return "English"
        case .chinese:  return "Chinese"
        case .russian:  return "Russian"
        case .spanish:  return "Spanish"
        case .french:   return "French"
        case .japanese:  return "Japanese"
        }
    }

    var nativeName: String {
        switch self {
        case .english:  return "English"
        case .chinese:  return "中文"
        case .russian:  return "Русский"
        case .spanish:  return "Español"
        case .french:   return "Français"
        case .japanese:  return "日本語"
        }
    }

    var localeIdentifier: String {
        switch self {
        case .english:  return "en-US"
        case .chinese:  return "zh-CN"
        case .russian:  return "ru-RU"
        case .spanish:  return "es-ES"
        case .french:   return "fr-FR"
        case .japanese:  return "ja-JP"
        }
    }

    /// System prompt instruction telling the LLM what language to respond in.
    var systemPromptInstruction: String {
        switch self {
        case .english:
            return "" // Default, no instruction needed
        case .chinese:
            return "\n\n**LANGUAGE: You MUST respond in Chinese (简体中文). All text responses must be in Chinese. Tool arguments (file paths, app names) stay in their original language/English.**"
        case .russian:
            return "\n\n**LANGUAGE: You MUST respond in Russian (Русский). All text responses must be in Russian. Tool arguments (file paths, app names) stay in their original language/English.**"
        case .spanish:
            return "\n\n**LANGUAGE: You MUST respond in Spanish (Español). All text responses must be in Spanish. Tool arguments (file paths, app names) stay in their original language/English.**"
        case .french:
            return "\n\n**LANGUAGE: You MUST respond in French (Français). All text responses must be in French. Tool arguments (file paths, app names) stay in their original language/English.**"
        case .japanese:
            return "\n\n**LANGUAGE: You MUST respond in Japanese (日本語). All text responses must be in Japanese. Tool arguments (file paths, app names) stay in their original language/English.**"
        }
    }

    // MARK: - Humor Messages Per Language

    var humorMessages: HumorMessages {
        switch self {
        case .english:  return Self.englishHumor
        case .chinese:  return Self.chineseHumor
        case .russian:  return Self.russianHumor
        case .spanish:  return Self.spanishHumor
        case .french:   return Self.frenchHumor
        case .japanese:  return Self.japaneseHumor
        }
    }

    // =========================================================================
    // ENGLISH (original)
    // =========================================================================

    private static let englishHumor = HumorMessages(
        thinkingMessages: [
            "Consulting the ancient scrolls...",
            "Asking my mom for advice...",
            "Googling it (don't tell anyone)...",
            "Pretending to think really hard...",
            "Loading braincells...",
            "Hold on, my hamster is powering the wheel...",
            "Sacrificing a CPU cycle to the silicon gods...",
            "Let me put on my thinking cap... ok it's on...",
            "Running advanced calculations (2+2=?)...",
            "Downloading more RAM real quick...",
            "Warming up my neurons...",
            "Spinning up the motivation engine...",
            "Channeling my inner Einstein...",
            "Doing the thing... you know... THE thing...",
            "Negotiating with the cloud...",
            "Bribing the API gods...",
            "Entering the matrix...",
            "Hacking the mainframe (not really)...",
            "Summoning digital spirits...",
            "Microwaving some hot takes...",
        ],
        toolMessages: [
            "launch_app": ["Waking up your app from its nap...", "Summoning the app from the shadow realm...", "Dragging the app out of bed...", "Politely asking the app to show up to work...", "Bribing the app with CPU cycles..."],
            "quit_app": ["Showing the app the exit door...", "Telling the app it's fired...", "App has been voted off the island...", "Sending the app to the shadow realm...", "The app has left the chat..."],
            "force_quit_app": ["Yeeting the app into oblivion...", "Performing emergency app surgery...", "DROP TABLE app; --", "The app chose violence, and so did I..."],
            "set_volume": ["Adjusting the noise machine...", "Twisting the volume knob aggressively...", "Making your speakers go brrr...", "Calibrating audio vibes...", "Telling your speakers how loud to be..."],
            "music_play": ["Dropping the beat...", "DJ Executer in the house...", "Pressing play with dramatic flair...", "Unleashing the tunes..."],
            "music_pause": ["Hitting the brakes on the vibes...", "Putting the music in timeout...", "The DJ needs a bathroom break...", "Freezing the beat mid-drop..."],
            "capture_screen": ["Say cheese! Taking the pic...", "Screenshotting your digital life...", "Capturing this moment for eternity...", "Committing your screen to memory..."],
            "lock_screen": ["Deploying anti-sibling defense system...", "Activating Fort Knox mode...", "Nobody gets in. Nobody.", "Engaging privacy shields..."],
            "run_shell_command": ["Hacking the mainframe (legally)...", "Executing forbidden terminal arts...", "Doing nerdy computer stuff...", "Speaking to the machine in its native tongue..."],
            "fetch_url_content": ["Stalking the internet for answers...", "Crawling the web like a spider...", "Reading the internet so you don't have to...", "Downloading knowledge..."],
        ],
        genericToolMessages: [
            "Doing mysterious computer things...", "Working my magic...", "Hold my beer...",
            "Trust me, I know what I'm doing...", "Executing plan B (there was no plan A)...",
            "Making things happen behind the scenes...", "This is where the magic happens...",
            "Pulling strings in the digital realm...", "Operating heavy machinery...",
            "Deploying the secret weapon...", "Running classified operations...",
            "Activating the thing that does the stuff...", "Doing what the AI does best...",
            "Loading awesome.exe...", "Compiling some vibes...",
            "Allocating maximum effort...", "Engaging warp drive...",
        ],
        successPrefixes: [
            "Done! ", "Boom! ", "Ez. ", "Mission accomplished. ",
            "Your wish is my command. ", "Nailed it. ", "Consider it done. ",
            "No cap, that's handled. ", "Just like that. ", "Piece of cake. ",
        ],
        healthyMessages: [
            "Your Mac is vibing", "Your Mac is absolutely thriving",
            "Your Mac is built different", "Your Mac woke up and chose excellence",
            "Your Mac passed the vibe check", "Your Mac is in its prime",
        ],
        diskWarningMessages: [
            "Your Mac is getting a little thicc",
            "Storage looking packed... time to Marie Kondo some files?",
            "Your disk is giving 'I have too many screenshots' energy",
        ]
    )

    // =========================================================================
    // CHINESE (中文)
    // =========================================================================

    private static let chineseHumor = HumorMessages(
        thinkingMessages: [
            "正在翻阅古籍秘笈...",
            "脑子正在加载中，请稍候...",
            "正在偷偷百度（别告诉别人）...",
            "正在假装很努力地思考...",
            "脑细胞正在开机...",
            "等一下，小仓鼠正在跑轮子发电...",
            "正在向硅谷众神献祭CPU...",
            "让我戴上我的思考帽...好了戴上了...",
            "正在进行高级运算（1+1=?）...",
            "马上下载更多内存...",
            "正在预热神经元...",
            "正在启动摸鱼引擎...",
            "正在召唤我体内的爱因斯坦...",
            "正在做那个事...你懂的...",
            "正在跟云端谈判...",
            "正在贿赂API之神...",
            "进入黑客帝国中...",
            "正在入侵主机（开玩笑的）...",
            "正在召唤数字精灵...",
            "正在微波加热辣评...",
        ],
        toolMessages: [
            "launch_app": ["正在把app从被窝里拉出来...", "正在从异次元召唤app...", "正在叫app起床上班...", "正在用CPU贿赂app..."],
            "quit_app": ["正在送app上路...", "app已被投票淘汰...", "正在把app送去异次元...", "app已退出群聊..."],
            "set_volume": ["正在调整噪音机器...", "正在疯狂拧音量旋钮...", "正在让你的音箱嗡嗡叫...", "正在校准音频氛围..."],
            "music_play": ["正在甩节拍...", "DJ Executer闪亮登场...", "正在帅气地按下播放键...", "释放音浪中..."],
            "capture_screen": ["茄子！拍照中...", "正在截取你的数字生活...", "正在将此刻定格为永恒..."],
            "lock_screen": ["正在部署防熊孩子系统...", "正在激活诺克斯堡模式...", "谁也别想进来...", "正在启动隐私护盾..."],
            "run_shell_command": ["正在入侵主机（合法的）...", "正在施展禁术...", "正在做极客才懂的事...", "正在用机器的母语与它交谈..."],
            "fetch_url_content": ["正在网上冲浪找答案...", "正在像蜘蛛一样爬网页...", "正在替你读完整个互联网..."],
        ],
        genericToolMessages: [
            "正在做神秘的电脑操作...", "正在施展魔法...", "hold住...",
            "相信我，我知道我在干嘛...", "正在执行B计划（没有A计划）...",
            "正在幕后搞事情...", "奇迹发生的地方...",
            "正在操控数字世界...", "正在操作重型机械...",
            "正在部署秘密武器...", "正在执行机密任务...",
            "正在激活那个做那个事的东西...", "正在做AI最擅长的事...",
            "Loading 牛逼.exe...", "正在编译氛围...",
        ],
        successPrefixes: [
            "搞定！", "嘭！", "小意思。", "任务完成。",
            "遵命。", "拿下了。", "完事儿。",
            "稳稳的。", "就这么简单。", "小菜一碟。",
        ],
        healthyMessages: [
            "你的Mac状态拉满", "你的Mac生龙活虎",
            "你的Mac与众不同", "你的Mac今天选择了卓越",
            "你的Mac通过了氛围检测", "你的Mac正值巅峰",
        ],
        diskWarningMessages: [
            "你的Mac有点太胖了",
            "存储空间告急...是时候断舍离了？",
            "你的磁盘散发着「截图太多」的气息",
        ]
    )

    // =========================================================================
    // RUSSIAN (Русский)
    // =========================================================================

    private static let russianHumor = HumorMessages(
        thinkingMessages: [
            "Консультируюсь с древними свитками...",
            "Загружаю мозговые клетки...",
            "Гуглю (никому не говори)...",
            "Делаю вид, что усиленно думаю...",
            "Подождите, хомяк крутит колесо...",
            "Приношу жертву богам кремния...",
            "Надеваю шапку-думалку...",
            "Провожу сложные вычисления (2+2=?)...",
            "Срочно скачиваю ещё оперативки...",
            "Разогреваю нейроны...",
            "Запускаю двигатель мотивации...",
            "Призываю внутреннего Эйнштейна...",
            "Делаю ТУ САМУЮ штуку...",
            "Договариваюсь с облаком...",
            "Подкупаю богов API...",
            "Вхожу в матрицу...",
            "Взламываю мейнфрейм (шутка)...",
            "Призываю цифровых духов...",
        ],
        toolMessages: [
            "launch_app": ["Бужу приложение от спячки...", "Призываю приложение из царства теней...", "Вытаскиваю приложение из кровати...", "Подкупаю приложение циклами процессора..."],
            "quit_app": ["Показываю приложению дверь...", "Приложение уволено...", "Приложение покинуло чат...", "Отправляю приложение в небытие..."],
            "set_volume": ["Кручу громкость...", "Настраиваю шумомашину...", "Заставляю колонки вжжж...", "Калибрую звуковые вайбы..."],
            "music_play": ["Бросаю бит...", "DJ Executer в деле...", "Нажимаю плей с драматизмом...", "Выпускаю мелодии на волю..."],
            "capture_screen": ["Сыр! Фоткаю...", "Скриншочу вашу цифровую жизнь...", "Запечатлеваю момент навечно..."],
            "lock_screen": ["Активирую систему «Форт Нокс»...", "Никто не войдёт. Никто.", "Включаю щиты конфиденциальности..."],
            "run_shell_command": ["Взламываю мейнфрейм (легально)...", "Выполняю запретные искусства терминала...", "Разговариваю с машиной на её языке..."],
        ],
        genericToolMessages: [
            "Делаю загадочные компьютерные штуки...", "Творю магию...", "Подержи моё пиво...",
            "Поверь, я знаю что делаю...", "Выполняю план Б (плана А не было)...",
            "Работаю за кулисами...", "Тут происходит магия...",
            "Дёргаю за ниточки...", "Управляю тяжёлой техникой...",
            "Развёртываю секретное оружие...", "Выполняю секретную миссию...",
            "Загружаю awesome.exe...", "Компилирую вайбы...",
        ],
        successPrefixes: [
            "Готово! ", "Бум! ", "Изи. ", "Миссия выполнена. ",
            "Ваше желание — моя команда. ", "Сделано. ", "Считай, готово. ",
            "Без проблем. ", "Раз-два и готово. ", "Проще пареной репы. ",
        ],
        healthyMessages: [
            "Твой Mac в отличной форме", "Твой Mac просто расцветает",
            "Твой Mac — особенный", "Твой Mac выбрал путь величия",
            "Твой Mac прошёл проверку вайбов", "Твой Mac на пике формы",
        ],
        diskWarningMessages: [
            "Твой Mac немного потолстел",
            "Место на диске заканчивается... пора устроить уборку?",
            "Диск кричит «слишком много скриншотов»",
        ]
    )

    // =========================================================================
    // SPANISH (Español)
    // =========================================================================

    private static let spanishHumor = HumorMessages(
        thinkingMessages: [
            "Consultando los pergaminos antiguos...",
            "Cargando neuronas...",
            "Googleando (que no se entere nadie)...",
            "Fingiendo que pienso muy fuerte...",
            "Espera, el hámster está corriendo en la rueda...",
            "Sacrificando un ciclo de CPU a los dioses del silicio...",
            "Poniéndome el gorro de pensar...",
            "Haciendo cálculos avanzados (2+2=?)...",
            "Descargando más RAM...",
            "Calentando mis neuronas...",
            "Encendiendo el motor de motivación...",
            "Canalizando mi Einstein interior...",
            "Haciendo LA cosa... ya sabes cuál...",
            "Negociando con la nube...",
            "Sobornando a los dioses de la API...",
            "Entrando en la matrix...",
            "Hackeando el mainframe (es broma)...",
            "Invocando espíritus digitales...",
        ],
        toolMessages: [
            "launch_app": ["Despertando la app de su siesta...", "Invocando la app del más allá...", "Sacando la app de la cama...", "Sobornando la app con CPU..."],
            "quit_app": ["Enseñándole la puerta a la app...", "La app ha sido despedida...", "La app ha abandonado el chat...", "Enviando la app al otro mundo..."],
            "set_volume": ["Ajustando la máquina de ruido...", "Girando la perilla con agresividad...", "Haciendo que los altavoces vibren...", "Calibrando vibraciones sonoras..."],
            "music_play": ["Soltando el beat...", "DJ Executer en la casa...", "Presionando play con estilo...", "Liberando las melodías..."],
            "capture_screen": ["¡Patata! Sacando foto...", "Capturando tu vida digital...", "Inmortalizando este momento..."],
            "lock_screen": ["Activando sistema anti-hermanos...", "Modo Fort Knox activado...", "Nadie entra. Nadie.", "Escudos de privacidad activados..."],
            "run_shell_command": ["Hackeando el mainframe (legalmente)...", "Ejecutando artes prohibidas del terminal...", "Hablando con la máquina en su idioma..."],
        ],
        genericToolMessages: [
            "Haciendo cosas misteriosas de computadora...", "Haciendo mi magia...", "Sostén mi cerveza...",
            "Confía en mí, sé lo que hago...", "Ejecutando plan B (no había plan A)...",
            "Haciendo cosas tras bambalinas...", "Aquí ocurre la magia...",
            "Moviendo hilos en el mundo digital...", "Operando maquinaria pesada...",
            "Desplegando el arma secreta...", "Ejecutando operaciones clasificadas...",
            "Cargando awesome.exe...", "Compilando vibras...",
        ],
        successPrefixes: [
            "¡Listo! ", "¡Pum! ", "Fácil. ", "Misión cumplida. ",
            "Tus deseos son órdenes. ", "Clavado. ", "Considéralo hecho. ",
            "Pan comido. ", "Así de simple. ", "Hecho y derecho. ",
        ],
        healthyMessages: [
            "Tu Mac está vibrando alto", "Tu Mac está prosperando",
            "Tu Mac es diferente", "Tu Mac eligió la excelencia hoy",
            "Tu Mac pasó el chequeo de vibras", "Tu Mac está en su mejor momento",
        ],
        diskWarningMessages: [
            "Tu Mac está un poco gordito",
            "El almacenamiento está lleno... ¿hora de hacer limpieza?",
            "Tu disco tiene energía de 'demasiadas capturas de pantalla'",
        ]
    )

    // =========================================================================
    // FRENCH (Français)
    // =========================================================================

    private static let frenchHumor = HumorMessages(
        thinkingMessages: [
            "Consultation des parchemins anciens...",
            "Chargement des neurones...",
            "En train de googler (ne le dites à personne)...",
            "Je fais semblant de réfléchir très fort...",
            "Attendez, le hamster fait tourner la roue...",
            "Sacrifice d'un cycle CPU aux dieux du silicium...",
            "Je mets mon chapeau de réflexion...",
            "Calculs avancés en cours (2+2=?)...",
            "Téléchargement de RAM supplémentaire...",
            "Préchauffage des neurones...",
            "Démarrage du moteur de motivation...",
            "Canalisation de mon Einstein intérieur...",
            "En train de faire LE truc... tu vois lequel...",
            "Négociation avec le cloud...",
            "Corruption des dieux de l'API...",
            "Entrée dans la matrice...",
            "Piratage du mainframe (c'est une blague)...",
            "Invocation d'esprits numériques...",
        ],
        toolMessages: [
            "launch_app": ["Réveil de l'app de sa sieste...", "Invocation de l'app depuis l'au-delà...", "L'app sort du lit...", "Corruption de l'app avec des cycles CPU..."],
            "quit_app": ["L'app voit la sortie...", "L'app est virée...", "L'app a quitté le chat...", "Envoi de l'app dans le néant..."],
            "set_volume": ["Réglage de la machine à bruit...", "Rotation agressive du bouton volume...", "Les enceintes vont faire brr...", "Calibrage des vibes audio..."],
            "music_play": ["Lâcher du beat...", "DJ Executer dans la place...", "Appui sur play avec panache...", "Libération des mélodies..."],
            "capture_screen": ["Cheese ! Photo en cours...", "Capture de votre vie numérique...", "Immortalisation de ce moment..."],
            "lock_screen": ["Activation du système anti-intrusion...", "Mode Fort Knox activé...", "Personne n'entre. Personne.", "Boucliers de confidentialité activés..."],
            "run_shell_command": ["Piratage du mainframe (légalement)...", "Exécution d'arts terminaux interdits...", "Communication avec la machine dans sa langue..."],
        ],
        genericToolMessages: [
            "Trucs mystérieux d'ordinateur en cours...", "Ma magie opère...", "Tiens ma bière...",
            "Fais-moi confiance, je sais ce que je fais...", "Exécution du plan B (y avait pas de plan A)...",
            "Manigances en coulisses...", "C'est ici que la magie opère...",
            "Manipulation de ficelles numériques...", "Opération de machinerie lourde...",
            "Déploiement de l'arme secrète...", "Opérations classifiées en cours...",
            "Chargement de awesome.exe...", "Compilation de vibes...",
        ],
        successPrefixes: [
            "Voilà ! ", "Boum ! ", "Easy. ", "Mission accomplie. ",
            "Vos désirs sont des ordres. ", "Réussi. ", "C'est fait. ",
            "Du gâteau. ", "Tout simplement. ", "Fait et bien fait. ",
        ],
        healthyMessages: [
            "Ton Mac est au top", "Ton Mac est en pleine forme",
            "Ton Mac est unique", "Ton Mac a choisi l'excellence aujourd'hui",
            "Ton Mac a passé le test de vibes", "Ton Mac est à son apogée",
        ],
        diskWarningMessages: [
            "Ton Mac prend un peu de poids",
            "Le stockage est plein... temps de faire du ménage ?",
            "Ton disque dégage une énergie 'trop de captures d'écran'",
        ]
    )

    // =========================================================================
    // JAPANESE (日本語)
    // =========================================================================

    private static let japaneseHumor = HumorMessages(
        thinkingMessages: [
            "古代の巻物を参照中...",
            "脳細胞をロード中...",
            "こっそりググってます（内緒で）...",
            "すごく考えてるフリをしています...",
            "ハムスターが回し車を回してます...",
            "シリコンの神にCPUを捧げ中...",
            "考える帽子をかぶります...",
            "高度な計算中（2+2=?）...",
            "RAMを追加ダウンロード中...",
            "ニューロンをウォームアップ中...",
            "やる気エンジンを起動中...",
            "内なるアインシュタインを召喚中...",
            "あの事をやってます...わかるでしょ...",
            "クラウドと交渉中...",
            "APIの神々に賄賂を...",
            "マトリックスに入ります...",
            "メインフレームをハック中（嘘です）...",
            "デジタル精霊を召喚中...",
        ],
        toolMessages: [
            "launch_app": ["アプリを昼寝から起こし中...", "異次元からアプリを召喚中...", "アプリをベッドから引っ張り出し中...", "CPUでアプリを買収中..."],
            "quit_app": ["アプリに出口を案内中...", "アプリをクビにしました...", "アプリがチャットを退出しました...", "アプリを異次元に送還中..."],
            "set_volume": ["ノイズマシンを調整中...", "音量ノブを激しく回し中...", "スピーカーをブーンさせ中...", "オーディオバイブスを調整中..."],
            "music_play": ["ビートをドロップ中...", "DJ Executerが登場...", "ドラマチックに再生ボタンを押し中...", "チューンを解放中..."],
            "capture_screen": ["はいチーズ！撮影中...", "デジタルライフをスクショ中...", "この瞬間を永遠に記録中..."],
            "lock_screen": ["対兄弟防御システム起動中...", "フォートノックスモード起動...", "誰も入れません。誰も。", "プライバシーシールド展開中..."],
            "run_shell_command": ["メインフレームをハック中（合法です）...", "禁断のターミナル術を実行中...", "マシンの母国語で会話中..."],
        ],
        genericToolMessages: [
            "神秘的なコンピュータ操作中...", "魔法を使い中...", "ちょっと待って...",
            "信じて、何やってるかわかってるから...", "プランBを実行中（プランAはなかった）...",
            "裏で色々やってます...", "ここで魔法が起きる...",
            "デジタル世界の糸を引いてます...", "重機を操作中...",
            "秘密兵器を展開中...", "機密作戦を実行中...",
            "awesome.exeをロード中...", "バイブスをコンパイル中...",
        ],
        successPrefixes: [
            "完了！", "ドーン！", "楽勝。", "ミッション完了。",
            "お望みのままに。", "バッチリ。", "できました。",
            "余裕でした。", "こんな簡単。", "朝飯前です。",
        ],
        healthyMessages: [
            "あなたのMacは絶好調", "あなたのMacは元気いっぱい",
            "あなたのMacは特別", "あなたのMacは今日も最高を選んだ",
            "あなたのMacはバイブチェック合格", "あなたのMacは全盛期",
        ],
        diskWarningMessages: [
            "あなたのMacはちょっと太り気味",
            "ストレージがパンパン...断捨離の時間？",
            "ディスクが「スクショ多すぎ」オーラを放ってます",
        ]
    )
}

// MARK: - Language Manager

class LanguageManager {
    static let shared = LanguageManager()
    private init() {}

    var currentLanguage: AppLanguage {
        get {
            if let raw = UserDefaults.standard.string(forKey: "app_language"),
               let lang = AppLanguage(rawValue: raw) { return lang }
            return .english
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "app_language")
        }
    }

    var humorMessages: HumorMessages {
        currentLanguage.humorMessages
    }

    func systemPromptLanguageInstruction() -> String {
        currentLanguage.systemPromptInstruction
    }

    func speechLocale() -> Locale {
        Locale(identifier: currentLanguage.localeIdentifier)
    }
}
