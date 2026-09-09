import React, { useState } from 'react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { motion } from 'motion/react';
import { Sparkles, User, Lock, Loader2, ArrowRight } from 'lucide-react';
import { Toast } from '@capacitor/toast';
import { API_BASE_URL } from '../../config';

interface AuthScreenProps {
  onLogin: (user: { id: string; username: string }) => void;
}

export const AuthScreen: React.FC<AuthScreenProps> = ({ onLogin }) => {
  const [isRegister, setIsRegister] = useState(false);
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const handleSkip = () => {
    onLogin({ id: 'guest', username: '游客' });
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!username || !password) return;

    setIsLoading(true);
    setError(null);
    try {
      const baseUrl = API_BASE_URL;
      const endpoint = isRegister ? '/api/register' : '/api/login';
      const clientSessionId = localStorage.getItem('chat_client_session_id') || `web_${Date.now()}_${Math.random().toString(36).substring(2, 9)}`;
      localStorage.setItem('chat_client_session_id', clientSessionId);

      console.log(`Sending request to ${baseUrl}${endpoint}`);
      const res = await fetch(`${baseUrl}${endpoint}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          username,
          password,
          deviceType: 'desktop',
          clientSessionId,
        }),
      });

      const data = await res.json();
      console.log('Response data:', data);
      if (res.ok) {
        try { await Toast.show({ text: isRegister ? '注册成功' : '登录成功' }); } catch (e) { console.warn('Toast failed', e); }
        onLogin(data.user);
      } else {
        setError(data.error || '操作失败');
        try { await Toast.show({ text: data.error || '操作失败' }); } catch (e) { console.warn('Toast failed', e); }
      }
    } catch (err) {
      console.error('Fetch error:', err);
      setError('网络连接失败，请检查服务器');
      try { await Toast.show({ text: '网络连接失败，请检查服务器' }); } catch (e) { console.warn('Toast failed', e); }
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-background/80 backdrop-blur-md p-6">
      <motion.div 
        initial={{ opacity: 0, scale: 0.95, y: 20 }}
        animate={{ opacity: 1, scale: 1, y: 0 }}
        className="w-full max-w-[400px] bg-card border rounded-3xl p-8 shadow-2xl relative overflow-hidden"
      >
        {/* Background Decor */}
        <div className="absolute -top-24 -right-24 w-48 h-48 bg-primary/10 rounded-full blur-3xl pointer-events-none" />
        <div className="absolute -bottom-24 -left-24 w-48 h-48 bg-primary/5 rounded-full blur-3xl pointer-events-none" />

        <div className="flex flex-col items-center gap-6 relative z-10">
          <div className="w-16 h-16 rounded-2xl bg-primary flex items-center justify-center shadow-lg shadow-primary/20">
            <Sparkles size={32} className="text-primary-foreground" />
          </div>
          
          <div className="text-center space-y-2">
            <h1 className="text-2xl font-bold tracking-tight">
              {isRegister ? '创建您的账号' : '欢迎回来'}
            </h1>
            <p className="text-sm text-muted-foreground">
              使用本地存储，您的数据仅保存在本服务器
            </p>
          </div>

          <form onSubmit={handleSubmit} className="w-full space-y-4 pt-2">
            {error && (
              <div className="p-3 bg-red-500/10 border border-red-500/20 text-red-500 rounded-2xl text-sm text-center">
                {error}
              </div>
            )}
            <div className="relative group">
              <User size={18} className="absolute left-4 top-1/2 -translate-y-1/2 text-muted-foreground group-focus-within:text-primary transition-colors" />
              <Input
                placeholder="用户名 (或 ID)"
                value={username}
                onChange={(e) => setUsername(e.target.value)}
                className="h-12 pl-12 rounded-2xl bg-muted/50 border-muted-foreground/20 focus-visible:ring-primary/20"
                disabled={isLoading}
              />
            </div>
            
            <div className="relative group">
              <Lock size={18} className="absolute left-4 top-1/2 -translate-y-1/2 text-muted-foreground group-focus-within:text-primary transition-colors" />
              <Input
                type="password"
                placeholder="密码"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                className="h-12 pl-12 rounded-2xl bg-muted/50 border-muted-foreground/20 focus-visible:ring-primary/20"
                disabled={isLoading}
              />
            </div>

            <Button 
              type="submit" 
              className="w-full h-12 rounded-2xl text-base font-semibold transition-all active:scale-95 shadow-lg shadow-primary/30"
              disabled={isLoading}
            >
              {isLoading ? (
                <Loader2 className="animate-spin mr-2" />
              ) : (
                <>
                  {isRegister ? '注册并进入' : '即刻登录'}
                  <ArrowRight size={18} className="ml-2" />
                </>
              )}
            </Button>
            <Button 
              type="button"
              onClick={handleSkip}
              className="w-full h-12 rounded-2xl text-base font-semibold transition-all active:scale-95 shadow-lg shadow-primary/30"
              disabled={isLoading}
            >
              游客模式
            </Button>
          </form>

          <button 
            type="button"
            onClick={() => setIsRegister(!isRegister)}
            className="text-sm text-muted-foreground hover:text-primary transition-colors"
            disabled={isLoading}
          >
            {isRegister ? '已有账号？点此登录' : '没有账号？点此创建一个'}
          </button>
        </div>
      </motion.div>
    </div>
  );
};
